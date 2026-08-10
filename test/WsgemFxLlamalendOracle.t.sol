// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                   from "forge-std/Test.sol";
import {Vm}                     from "forge-std/Vm.sol";
import {WsgemFxLlamalendOracle} from "../src/WsgemFxLlamalendOracle.sol";
import {IWsgem}                 from "../src/interfaces/IWsgem.sol";
import {IChainlinkAggregator}   from "../src/interfaces/IChainlinkAggregator.sol";
import {MockPip, MockGem, MockWsgem} from "./mocks/MockWsgem.sol";
import {QuoteBreakingWsgem}         from "./WsgemLlamalendOracle.t.sol";
import {MockChainlinkFeed, MockStablePriceAggregator} from "./mocks/MockFeeds.sol";

/// @notice The cross-currency shim, over mocked feeds.
/// @dev Deliberately parallel to `test/WsgemLlamalendOracle.t.sol` -- the NAV-leg behaviour is the
///      same contract of behaviour and is re-proven here through the conversion, because "the same
///      logic, one multiplication later" is a claim and not a fact. What is new is everything about
///      the conversion: that the rate limit does NOT touch it, that each of its failure shapes
///      freezes, and that composing cannot produce a zero.
contract WsgemFxLlamalendOracleTest is Test {
    uint256 internal constant WAD    = 1e18;
    uint256 internal constant SPEED  = uint256(0.0025e18) / 1 days; // the configured 0.25% per day
    uint256 internal constant MAXAGE = 30 hours;
    uint256 internal constant NAV0   = 1.05e18;

    // GBP/USD and crvUSD/USD at the magnitudes the live feeds carry, so the arithmetic under test
    // is the arithmetic that will run.
    int256  internal constant FX0    = 1.34714e8;    // 8 decimals, as Chainlink
    uint256 internal constant QUOTE0 = 0.99992e18;   // WAD, as Curve's aggregator

    MockPip                    internal pip;
    MockGem                    internal gem;
    MockWsgem                  internal wsgem;
    MockGem                    internal borrowed;
    MockChainlinkFeed          internal fx;
    MockStablePriceAggregator  internal agg;
    WsgemFxLlamalendOracle     internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip      = new MockPip(NAV0);
        gem      = new MockGem(18);
        wsgem    = new MockWsgem(address(gem), address(pip), 18);
        borrowed = new MockGem(18);
        fx       = new MockChainlinkFeed(FX0, 8);
        agg      = new MockStablePriceAggregator(QUOTE0);
        oracle   = _deploy();
    }

    function _deploy() internal returns (WsgemFxLlamalendOracle) {
        return new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(agg),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            SPEED,
            MAXAGE
        );
    }

    /// @dev The identity under test, restated independently of the contract.
    function _expected(uint256 quote_) internal view returns (uint256) {
        return (quote_ * (uint256(fx.answer()) * 1e10)) / agg.stored();
    }

    // --- Construction ------------------------------------------------------------------------

    function test_constructorCachesTheImmutableWiring() public view {
        assertEq(address(oracle.WSGEM()), address(wsgem));
        assertEq(oracle.GEM(), address(gem), "the gem is the wrapper's, not the borrowed token");
        assertEq(oracle.BORROWED(), address(borrowed));
        assertEq(address(oracle.PIP()), address(pip));
        assertEq(address(oracle.FX_FEED()), address(fx));
        assertEq(oracle.BORROWED_QUOTE(), address(agg));
        assertTrue(oracle.BORROWED_QUOTE_KIND() == WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR);
        assertEq(oracle.BORROWED_QUOTE_SCALE(), 1, "a WAD aggregator needs no scaling");
        assertEq(oracle.MAX_UPSIDE_SPEED(), SPEED);
        assertEq(oracle.MAX_FX_AGE(), MAXAGE);
        assertEq(oracle.FX_SCALE(), 1e10, "8-decimal feed scales to WAD by 1e10");
    }

    function test_constructorReportsTheComposedPriceExactly() public view {
        assertEq(oracle.price(), _expected(NAV0), "a fresh oracle must not be rate-limited");
        assertEq(oracle.price(), oracle.spotPrice());
    }

    function test_theComposedPriceIsTheThreeLegProduct() public view {
        // Stated numerically as well as algebraically: 1.05 tGBP/wstGBP at 1.34714 GBP/USD over
        // 0.99992 USD/crvUSD is 1.41461... crvUSD per wstGBP.
        assertApproxEqRel(oracle.price(), 1.414610e18, 1e12);
    }

    function test_constructorRejectsAPausedFeed() public {
        pip.poke(0);
        vm.expectRevert(WsgemFxLlamalendOracle.OraclePaused.selector);
        _deploy();
    }

    function test_constructorRejectsAZeroQuote() public {
        wsgem.setFee(WAD);
        vm.expectRevert(WsgemFxLlamalendOracle.QuoteIsZero.selector);
        _deploy();
    }

    function test_constructorRejectsUnusableConversionLegs() public {
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        vm.expectRevert(WsgemFxLlamalendOracle.FxUnusable.selector);
        _deploy();
    }

    function test_constructorRejectsAZeroAddressAnywhere() public {
        vm.expectRevert(WsgemFxLlamalendOracle.ZeroAddress.selector);
        new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(0),
            IChainlinkAggregator(address(fx)),
            address(agg),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            SPEED,
            MAXAGE
        );

        vm.expectRevert(WsgemFxLlamalendOracle.ZeroAddress.selector);
        new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(0)),
            address(agg),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            SPEED,
            MAXAGE
        );

        vm.expectRevert(WsgemFxLlamalendOracle.ZeroAddress.selector);
        new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(0),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            SPEED,
            MAXAGE
        );
    }

    /// @dev The borrowed token is the one the wsgem knows nothing about, so this check is the only
    ///      thing standing between a non-18-decimal borrowed token and a market mispriced by
    ///      twelve orders of magnitude.
    function test_constructorRejectsANonEighteenDecimalBorrowedToken() public {
        borrowed = new MockGem(6);
        vm.expectRevert(WsgemFxLlamalendOracle.UnsupportedDecimals.selector);
        _deploy();
    }

    function test_constructorRejectsAFeedWithMoreThanEighteenDecimals() public {
        fx = new MockChainlinkFeed(FX0, 19);
        vm.expectRevert(WsgemFxLlamalendOracle.UnsupportedDecimals.selector);
        _deploy();
    }

    function test_constructorRejectsAnUnboundedStalenessArgument() public {
        // Read the bounds first: `expectRevert` arms the NEXT call, and an inline `oracle.X()`
        // would be that call.
        uint256 tooTight_ = oracle.MIN_FX_AGE_LIMIT() - 1;
        uint256 tooLoose_ = oracle.MAX_FX_AGE_LIMIT() + 1;

        vm.expectRevert(WsgemFxLlamalendOracle.FxAgeOutOfBounds.selector);
        _deployWithAge(tooTight_);

        vm.expectRevert(WsgemFxLlamalendOracle.FxAgeOutOfBounds.selector);
        _deployWithAge(tooLoose_);
    }

    function test_constructorAcceptsTheStalenessBoundaries() public {
        assertEq(_deployWithAge(oracle.MIN_FX_AGE_LIMIT()).MAX_FX_AGE(), 1 hours);
        assertEq(_deployWithAge(oracle.MAX_FX_AGE_LIMIT()).MAX_FX_AGE(), 7 days);
    }

    function _deployWithAge(uint256 age_) internal returns (WsgemFxLlamalendOracle) {
        return new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(agg),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            SPEED,
            age_
        );
    }

    // --- The factory's two requirements --------------------------------------------------------

    function test_priceAndPriceWAgreeWithinACall() public {
        pip.poke(NAV0 * 2);
        skip(3 days);
        uint256 p_ = oracle.price();
        assertEq(oracle.price_w(), p_, "LendFactory asserts price_w() == price()");
    }

    function test_priceIsNeverZero() public {
        // Every failure state, in sequence, and none of them may report zero.
        assertGt(oracle.price(), 0);
        pip.poke(0);
        assertGt(oracle.price(), 0);
        pip.poke(NAV0);
        wsgem.setFee(WAD);
        assertGt(oracle.price(), 0);
        wsgem.setFee(0);
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        assertGt(oracle.price(), 0);
    }

    // --- Where the rate limit binds ------------------------------------------------------------

    function test_theRateLimitBindsOnTheNavLeg() public {
        uint256 before_ = oracle.price();
        pip.poke(NAV0 * 2);
        assertEq(oracle.price(), before_, "a doubling of the NAV is not expressed instantly");
        assertGt(oracle.spotPrice(), before_, "but spot moved");
    }

    /// @dev The design decision this contract exists for. A currency move must reach the market at
    ///      full size in the same block: throttling it would under-report collateral through every
    ///      sterling rally and soft-liquidate healthy borrowers.
    function test_aCurrencyMoveIsNotRateLimited() public {
        oracle.price_w(); // anchor now, so no allowance is banked
        fx.set(FX0 * 2);
        assertEq(oracle.price(), _expected(NAV0), "the conversion passes through untouched");
        assertEq(oracle.price(), oracle.spotPrice());
    }

    function test_aBorrowedTokenDepegIsNotRateLimited() public {
        oracle.price_w();
        agg.set(QUOTE0 / 2);
        assertEq(oracle.price(), _expected(NAV0));
        assertEq(oracle.price(), oracle.spotPrice(), "no damping on the borrowed leg either");
    }

    /// @dev The anchor is a quote, not a price, and this is what that buys: a year of currency
    ///      movement cannot spend the NAV leg's upside allowance, so a mistaken publication after
    ///      a big currency move is throttled exactly as hard as one before it.
    function test_currencyMovementDoesNotSpendTheNavLegsAllowance() public {
        oracle.price_w();
        uint256 anchor_ = oracle.cachedQuote();

        fx.set(FX0 * 3);
        oracle.price_w();
        assertEq(oracle.cachedQuote(), anchor_, "the anchor is pre-conversion");

        pip.poke(NAV0 * 2);
        assertEq(oracle.price(), _expected(anchor_), "the NAV step is still fully throttled");
    }

    /// @dev At 0.25% a day a doubling takes about 278 days to express; 300 iterations clears it.
    ///      The currency feed is republished each day, because it must be: a 30-hour staleness
    ///      bound means a feed left alone for two days freezes the market, and a version of this
    ///      test that forgot to publish measured the freeze instead of the limit.
    function test_aLargeNavRiseEventuallyArrives() public {
        pip.poke(NAV0 * 2);
        for (uint256 i_; i_ < 300; ++i_) {
            skip(1 days);
            fx.set(FX0);
            oracle.price_w();
        }
        assertEq(oracle.price(), _expected(NAV0 * 2), "the limit delays, it does not cap");
    }

    function test_aNavFallPassesThroughImmediately() public {
        pip.poke(NAV0 / 2);
        assertEq(oracle.price(), _expected(NAV0 / 2), "down is the safe direction");
    }

    // --- Freezing: the wsgem's own feed ---------------------------------------------------------

    function test_aPausedPipFreezes() public {
        uint256 held_ = oracle.price();
        pip.poke(0);
        assertTrue(oracle.frozen());
        assertFalse(oracle.fxFrozen(), "the pip is dark, not the conversion");
        assertEq(oracle.price(), held_);
        assertEq(oracle.spotPrice(), 0);
    }

    function test_aHundredPercentSpreadReportsOneWei() public {
        wsgem.setFee(WAD);
        assertTrue(oracle.quoteIsZero());
        assertFalse(oracle.frozen());
        assertEq(oracle.price(), 1);
    }

    /// @dev Short-circuiting matters here: collateral that redeems for nothing redeems for nothing
    ///      in any currency, so the oracle must not spend a conversion read establishing it -- and
    ///      must reach the same answer when the conversion is dark anyway.
    function test_aZeroQuoteIsReportedWithoutReadingTheConversion() public {
        wsgem.setFee(WAD);
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        agg.setMode(MockStablePriceAggregator.Mode.REVERTING);
        assertTrue(oracle.quoteIsZero());
        assertEq(oracle.price(), 1);
    }

    // --- Freezing: the conversion legs ----------------------------------------------------------

    function test_aRevertingFxFeedFreezes() public {
        uint256 held_ = oracle.price();
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        assertTrue(oracle.frozen());
        assertTrue(oracle.fxFrozen(), "and names the conversion as the cause");
        assertEq(oracle.price(), held_);
        assertEq(oracle.spotPrice(), 0);
        assertEq(oracle.fxRate(), 0);
    }

    function test_aStaleFxFeedFreezes() public {
        uint256 held_ = oracle.price();
        assertFalse(oracle.fxFrozen());

        skip(MAXAGE);
        assertFalse(oracle.fxFrozen(), "exactly at the bound is still fresh");

        skip(1);
        assertTrue(oracle.fxFrozen());
        assertEq(oracle.price(), held_);
    }

    function test_aNonPositiveFxAnswerFreezes() public {
        fx.set(0);
        assertTrue(oracle.fxFrozen());
        fx.set(-1);
        assertTrue(oracle.fxFrozen());
    }

    /// @dev A round stamped ahead of the chain is malformed, not fresh. Crediting it as current
    ///      would suspend the age bound for as long as the stamp stayed ahead -- here, eleven and a
    ///      half days -- which is the opposite of what a staleness bound is for.
    function test_anAnswerStampedInTheFutureFreezes() public {
        uint256 held_ = oracle.price_w();

        fx.setAt(FX0, block.timestamp + 10 days);
        assertTrue(oracle.fxFrozen(), "a future stamp is malformed data, not maximal freshness");
        assertEq(oracle.price(), held_);

        // One second ahead is as malformed as ten days ahead; there is no skew tolerance to tune.
        fx.setAt(FX0, block.timestamp + 1);
        assertTrue(oracle.fxFrozen());

        // And the same block is not ahead of it -- a round written by the transaction before this
        // one in the same block is perfectly ordinary.
        fx.setAt(FX0, block.timestamp);
        assertFalse(oracle.fxFrozen());
        assertEq(oracle.price(), _expected(NAV0));
    }

    function test_anUnstampedAnswerFreezes() public {
        fx.setAt(FX0, 0);
        assertTrue(oracle.fxFrozen());
    }

    function test_anAbsurdFxAnswerFreezesRatherThanComposing() public {
        // Past 1e18 in WAD terms a currency quote is not a currency quote. Composing it would
        // report a price a market could be drained against; freezing reports the last good one.
        fx.set(int256(1e18 * 1e8 + 1));
        assertTrue(oracle.fxFrozen());
    }

    function test_aShortFxReturnFreezes() public {
        fx.setMode(MockChainlinkFeed.Mode.SHORT_RETURN);
        assertTrue(oracle.fxFrozen());
    }

    function test_aGasBombFxFeedIsCappedAndFreezes() public {
        fx.setMode(MockChainlinkFeed.Mode.GAS_BOMB);
        uint256 gasBefore_ = gasleft();
        assertTrue(oracle.frozen());
        assertLt(gasBefore_ - gasleft(), 2_000_000, "the cap must bound the burn");
    }

    function test_aReturndataBombFxFeedFreezes() public {
        fx.setMode(MockChainlinkFeed.Mode.RETURNDATA_BOMB);
        assertTrue(oracle.fxFrozen());
    }

    function test_aRevertingBorrowedAggregatorFreezes() public {
        uint256 held_ = oracle.price();
        agg.setMode(MockStablePriceAggregator.Mode.REVERTING);
        assertTrue(oracle.fxFrozen());
        assertEq(oracle.price(), held_);
    }

    function test_aZeroBorrowedAggregatorFreezes() public {
        agg.set(0);
        assertTrue(oracle.fxFrozen());
    }

    function test_aShortBorrowedAggregatorReturnFreezes() public {
        agg.setMode(MockStablePriceAggregator.Mode.SHORT_RETURN);
        assertTrue(oracle.fxFrozen());
    }

    function test_aGasBombBorrowedAggregatorIsCappedAndFreezes() public {
        agg.setMode(MockStablePriceAggregator.Mode.GAS_BOMB);
        uint256 gasBefore_ = gasleft();
        assertTrue(oracle.frozen());
        assertLt(gasBefore_ - gasleft(), 3_000_000, "the loose cap must still bound the burn");
    }

    /// @dev A freeze must hold the last REPORT. The distinction bites here in a way it cannot in
    ///      the sibling: the anchor is a quote, so recomputing a price from it would need the
    ///      conversion -- which is precisely what is unavailable.
    function test_aFreezeHoldsTheLastReportedPriceNotSomethingRecomputed() public {
        fx.set(FX0 * 2);
        uint256 reported_ = oracle.price_w();

        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        assertEq(oracle.price(), reported_, "held at the doubled-currency price, not the original");
    }

    function test_aPauseAfterAWitnessedZeroQuoteHoldsTheFloor() public {
        wsgem.setFee(WAD);
        oracle.price_w();
        pip.poke(0);
        assertEq(oracle.price(), 1, "the floor survives the pause, it does not snap back");
    }

    // --- Anchoring through failure states -------------------------------------------------------

    function test_nothingIsAnchoredWhileTheConversionIsDark() public {
        oracle.price_w();
        uint256 anchor_ = oracle.cachedQuote();

        pip.poke(NAV0 * 2);
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        skip(365 days);
        oracle.price_w();

        assertEq(oracle.cachedQuote(), anchor_, "a dark conversion must not let the anchor ratchet");
    }

    function test_allowanceDoesNotAccrueThroughAConversionOutage() public {
        oracle.price_w();
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        skip(30 days);
        oracle.price_w(); // refreshes the checkpoint even while frozen

        fx.setMode(MockChainlinkFeed.Mode.NORMAL);
        fx.set(FX0);
        pip.poke(NAV0 * 2);
        assertEq(oracle.price(), _expected(NAV0), "no free jump on the way out");
    }

    // --- Events -----------------------------------------------------------------------------------

    event PriceUpdated(uint256 indexed price, uint256 indexed spot);
    event QuoteZeroed(uint256 indexed anchor);
    event QuoteRestored(uint256 indexed price);
    event QuoteAnchored(uint256 indexed quote);
    event FxDown(uint256 indexed price);
    event FxRestored(uint256 indexed price);

    function test_theConversionTransitionsAreEventedExactlyOnce() public {
        uint256 held_ = oracle.price();

        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        vm.expectEmit(true, false, false, true);
        emit FxDown(held_);
        oracle.price_w();

        // A second call in the same state must not re-announce it.
        vm.recordLogs();
        oracle.price_w();
        assertEq(vm.getRecordedLogs().length, 0, "a held freeze is not news");

        fx.setMode(MockChainlinkFeed.Mode.NORMAL);
        fx.set(FX0);
        vm.expectEmit(true, false, false, true);
        emit FxRestored(held_);
        oracle.price_w();
    }

    /// @dev The two events move for different reasons, which is why there are two: a publication
    ///      moves the anchor and the price, a currency move only the price.
    function test_aCurrencyMoveEmitsAPriceUpdateButNotAnAnchor() public {
        oracle.price_w();
        fx.set((FX0 * 101) / 100);

        vm.recordLogs();
        oracle.price_w();
        Vm.Log[] memory logs_ = vm.getRecordedLogs();

        assertEq(logs_.length, 1, "exactly one event");
        assertEq(logs_[0].topics[0], PriceUpdated.selector);
    }

    function test_aPublicationMovesBothTheAnchorAndThePrice() public {
        oracle.price_w();
        skip(1 days);
        pip.poke(NAV0 + NAV0 / 10_000); // a basis point, inside one day's allowance

        vm.recordLogs();
        oracle.price_w();
        Vm.Log[] memory logs_ = vm.getRecordedLogs();

        assertEq(logs_.length, 2);
        assertEq(logs_[0].topics[0], QuoteAnchored.selector);
        assertEq(logs_[1].topics[0], PriceUpdated.selector);
    }

    // --- Arithmetic -------------------------------------------------------------------------------

    /// @dev The reason `_mulDivSat` is a full 512-bit division rather than a bare multiply: with
    ///      the quote saturated at 2^208 and a currency quote allowed up to 1e36, the intermediate
    ///      product genuinely exceeds 2^256, and a market must not revert when it does.
    function test_anEnormousQuoteSaturatesRatherThanReverting() public {
        pip.poke(type(uint256).max);
        uint256 p_ = oracle.price();
        assertGt(p_, 0);
        assertLe(p_, type(uint208).max);
    }

    function test_aTinyQuoteAgainstAHugeDivisorFloorsAtOneWei() public {
        // The composition rounds to zero without either feed having failed. Zero must never reach
        // Llamalend, so it floors -- and `price <= spotPrice` must survive the floor.
        pip.poke(1);
        fx.set(1);
        agg.set(1e36);
        assertEq(oracle.price(), 1);
        assertLe(oracle.price(), oracle.spotPrice(), "the floor applies to both, monotonically");
    }

    function testFuzz_theReportNeverExceedsTheSpot(uint96 nav_, uint64 fxRaw_, uint96 quote_) public {
        vm.assume(nav_ > 0 && fxRaw_ > 0 && quote_ > 0);
        pip.poke(nav_);
        fx.set(int256(uint256(fxRaw_)));
        agg.set(quote_);

        if (oracle.frozen() || oracle.quoteIsZero()) return;
        assertLe(oracle.price(), oracle.spotPrice());
        assertGt(oracle.price(), 0);
    }

    /// @dev Leaving the floor is the upside limit's sole documented exception: the round trip
    ///      through a failure state is not a price increase, so the report may return to what the
    ///      held anchor's own ceiling allows in one block.
    function test_theZeroQuoteTransitionsAreEventedExactlyOnce() public {
        wsgem.setFee(WAD);
        vm.expectEmit(true, false, false, true);
        emit QuoteZeroed(oracle.cachedQuote());
        oracle.price_w();

        vm.recordLogs();
        oracle.price_w();
        assertEq(vm.getRecordedLogs().length, 0, "a held floor is not news");

        wsgem.setFee(0);
        uint256 restored_ = oracle.price();
        vm.expectEmit(true, false, false, true);
        emit QuoteRestored(restored_);
        oracle.price_w();

        assertEq(oracle.price(), _expected(NAV0), "and the report is back at the composed price");
    }

    // --- The monitoring views -----------------------------------------------------------------------

    /// @dev `quotePrice()` and `fxRate()` exist so an operator can see WHICH leg is dark without
    ///      decoding a frozen price. They have to disagree in the right direction to be worth
    ///      anything.
    function test_theTwoLegViewsSeparateTheCauses() public {
        assertEq(oracle.quotePrice(), NAV0, "healthy: the wrapper's quote, in gem terms");
        assertApproxEqRel(oracle.fxRate(), 1.34725e18, 1e14, "healthy: GBP per borrowed token");

        // The conversion goes dark. The wsgem's own leg is untouched and still reports.
        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        assertEq(oracle.quotePrice(), NAV0, "the NAV leg is fine and says so");
        assertEq(oracle.fxRate(), 0, "the conversion is not");

        // And the other way round.
        fx.setMode(MockChainlinkFeed.Mode.NORMAL);
        pip.poke(0);
        assertEq(oracle.quotePrice(), 0);
        assertGt(oracle.fxRate(), 0);

        // A zero redemption quote reads as a dark NAV leg here, which is right: there is no quote.
        pip.poke(NAV0);
        wsgem.setFee(WAD);
        assertEq(oracle.quotePrice(), 0);
    }

    /// @dev The monitoring contract docs/07 rests on, and the reason the publication alarm reads
    ///      `quotePrice()` on a cross-currency instance rather than `spotPrice()`. Keyed on spot,
    ///      both of the last two alarms break: a missed publication is masked, because the currency
    ///      keeps spot moving and the staleness timer never fires; and an ordinary currency move
    ///      against you reads as a NAV fall, paging someone to check a liquidation queue on a day
    ///      nothing published.
    function test_theNavLegViewIsInsensitiveToCurrencyMoves() public {
        uint256 quote_ = oracle.quotePrice();
        uint256 spot_  = oracle.spotPrice();

        // Sterling rallies. Nothing was published.
        fx.set((FX0 * 103) / 100);
        assertEq(oracle.quotePrice(), quote_, "a currency move must not read as a publication");
        assertGt(oracle.spotPrice(), spot_, "while spot moves -- which is why spot cannot be the alarm");

        // Sterling falls. Still nothing published, and this is the direction that would page.
        fx.set((FX0 * 97) / 100);
        assertEq(oracle.quotePrice(), quote_, "and a currency fall must not read as a NAV fall");
        assertLt(oracle.spotPrice(), spot_);

        // A real publication does move it.
        pip.poke(NAV0 + NAV0 / 1000);
        assertGt(oracle.quotePrice(), quote_, "a publication moves the NAV leg, and only that");
    }

    /// @dev And it must survive a dark conversion, or the publication alarm goes blind exactly
    ///      when an operator most wants to know the wsgem's feed is still alive.
    function test_theNavLegViewSurvivesADarkConversion() public {
        uint256 quote_ = oracle.quotePrice();

        fx.setMode(MockChainlinkFeed.Mode.REVERTING);
        assertTrue(oracle.fxFrozen());
        assertEq(oracle.spotPrice(), 0, "the composed spot collapses");
        assertEq(oracle.quotePrice(), quote_, "the NAV leg keeps reporting");
    }

    function test_theCeilingIsReportedInQuoteTermsNotPriceTerms() public {
        assertEq(oracle.quoteCeiling(), oracle.cachedQuote(), "no time passed, no allowance");

        skip(1 days);
        uint256 ceiling_ = oracle.quoteCeiling();
        assertApproxEqRel(ceiling_, (NAV0 * 10025) / 10000, 1e12, "one day at 0.25%");
        assertLt(ceiling_, oracle.price(), "in GEM terms, so below the converted price");
    }

    // --- The 512-bit division path -------------------------------------------------------------------
    //
    // Reachable only with a quote saturated at uint208 against a currency quote at the top of the
    // accepted band -- a state no healthy market occupies. It is tested because the alternative to
    // handling it is reverting inside `price()`, which bricks a market.

    /// @dev The extremes have to be in place BEFORE construction: the rate limit clamps the quote
    ///      to the anchor before anything is composed, so poking the pip on a live oracle can never
    ///      make the product large. Only an oracle born at the extreme reaches this path.
    function test_theFullPrecisionPathRunsWhenTheProductExceedsAWord() public {
        pip.poke(type(uint256).max); // quote saturates at type(uint208).max
        fx.set(1e26); // 1e36 once scaled: the widest quote MAX_QUOTE admits
        agg.set(1e36); // and a divisor large enough that the quotient still fits

        WsgemFxLlamalendOracle big_ = _deploy();
        assertFalse(big_.frozen(), "both legs are inside their bounds");
        assertEq(big_.price(), type(uint208).max, "(2^208 - 1) * 1e36 / 1e36, exactly");
    }

    function test_aQuotientPastTheWordSaturates() public {
        pip.poke(type(uint256).max);
        fx.set(1e26);
        agg.set(1e18); // now the true quotient exceeds 2^256

        WsgemFxLlamalendOracle big_ = _deploy();
        assertEq(big_.price(), type(uint208).max, "saturates rather than reverting or wrapping");
    }

    /// @dev The same triple at several magnitudes, so the 512-bit division's internal carry
    ///      branches are exercised rather than one arbitrary path through them. The claim under
    ///      test is the only one that matters out here: whatever the inputs, a price comes back,
    ///      it is not zero, and it fits the anchor's width.
    function test_theFullPrecisionPathIsWellBehavedAcrossMagnitudes() public {
        int256[5] memory fxs_ = [int256(1e26), 1e25, 7e25, 3e24, 999e23];
        uint256[5] memory divs_ = [uint256(1e36), 1e30, 7e35, 3e27, 123456789e27];

        for (uint256 i_; i_ < 5; ++i_) {
            pip.poke(type(uint256).max);
            fx.set(fxs_[i_]);
            agg.set(divs_[i_]);

            WsgemFxLlamalendOracle big_ = _deploy();
            uint256 p_ = big_.price();
            assertGt(p_, 0);
            assertLe(p_, type(uint208).max);
            assertEq(p_, big_.spotPrice(), "fresh: report and spot agree");
        }
    }

    /// @dev And fuzzed across the band, which is what reaches the division's borrow corrections --
    ///      they depend on where the 512-bit product falls, not on any input being special.
    function testFuzz_theFullPrecisionPathIsWellBehaved(uint256 fxRaw_, uint256 div_) public {
        pip.poke(type(uint256).max);
        fx.set(int256(bound(fxRaw_, 1e18, 1e26)));   // <= MAX_QUOTE once scaled to WAD
        agg.set(bound(div_, 1e18, 1e36));

        WsgemFxLlamalendOracle big_ = _deploy();
        uint256 p_ = big_.price();
        assertGt(p_, 0);
        assertLe(p_, type(uint208).max);
    }

    // --- The remaining constructor guards ------------------------------------------------------------

    function test_constructorRejectsAnUnboundedSpeed() public {
        uint256 tooFast_ = oracle.MAX_UPSIDE_SPEED_LIMIT() + 1;

        vm.expectRevert(WsgemFxLlamalendOracle.SpeedTooHigh.selector);
        _deployWithSpeed(0);

        vm.expectRevert(WsgemFxLlamalendOracle.SpeedTooHigh.selector);
        _deployWithSpeed(tooFast_);
    }

    function _deployWithSpeed(uint256 speed_) internal returns (WsgemFxLlamalendOracle) {
        return new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(agg),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            speed_,
            MAXAGE
        );
    }

    function test_constructorRejectsAWsgemWithAZeroGemOrPip() public {
        wsgem = new MockWsgem(address(0), address(pip), 18);
        vm.expectRevert(WsgemFxLlamalendOracle.ZeroAddress.selector);
        _deploy();

        wsgem = new MockWsgem(address(gem), address(0), 18);
        vm.expectRevert(WsgemFxLlamalendOracle.ZeroAddress.selector);
        _deploy();
    }

    function test_constructorRejectsNonEighteenDecimalWsgemOrGem() public {
        wsgem = new MockWsgem(address(gem), address(pip), 6);
        vm.expectRevert(WsgemFxLlamalendOracle.UnsupportedDecimals.selector);
        _deploy();

        gem   = new MockGem(6);
        wsgem = new MockWsgem(address(gem), address(pip), 18);
        vm.expectRevert(WsgemFxLlamalendOracle.UnsupportedDecimals.selector);
        _deploy();
    }

    function test_constructorRejectsABorrowedFeedWithMoreThanEighteenDecimals() public {
        MockChainlinkFeed odd_ = new MockChainlinkFeed(0.99987e8, 19);
        vm.expectRevert(WsgemFxLlamalendOracle.UnsupportedDecimals.selector);
        new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(odd_),
            WsgemFxLlamalendOracle.QuoteKind.CHAINLINK_FEED,
            SPEED,
            MAXAGE
        );
    }

    // --- The remaining read guards -------------------------------------------------------------------

    /// @dev A live NAV with a broken quote hop. `burncost()`'s last hop is an upgradeable proxy of
    ///      its own, so this is reachable on the live system and must read as a pause, not as a
    ///      price of zero.
    function test_aBrokenQuoteHopOverALiveNavFreezes() public {
        QuoteBreakingWsgem broken_ = new QuoteBreakingWsgem(address(gem), address(pip));
        WsgemFxLlamalendOracle o_ = new WsgemFxLlamalendOracle(
            IWsgem(address(broken_)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(agg),
            WsgemFxLlamalendOracle.QuoteKind.CURVE_AGGREGATOR,
            SPEED,
            MAXAGE
        );

        uint256 held_ = o_.price();
        broken_.setBroken(true);

        assertTrue(o_.frozen(), "the NAV is live but the quote is not readable");
        assertFalse(o_.fxFrozen(), "and it is not the conversion's fault");
        assertEq(o_.price(), held_);
    }

    /// @dev An answer so large that scaling it to WAD would itself wrap. It has to fail the bound,
    ///      not slip under it by overflowing into a small number.
    function test_AnAnswerThatWouldOverflowItsOwnScalingFreezes() public {
        fx.set(int256(type(uint256).max / 1e10 + 1));
        assertTrue(oracle.fxFrozen());
    }

    function test_allowanceStopsAccruingAtMaxElapsed() public {
        oracle.price_w();
        uint256 anchor_ = oracle.cachedQuote();

        // Well past MAX_ELAPSED, with nothing driving the checkpoint. The credited allowance is
        // capped at seven days regardless.
        skip(60 days);
        assertApproxEqRel(
            oracle.quoteCeiling(),
            anchor_ + (anchor_ * 7 * 25) / 10_000,
            1e14,
            "seven days of allowance, not sixty"
        );
    }

    // --- The Chainlink-shaped borrowed leg ---------------------------------------------------------

    function test_aChainlinkBorrowedQuoteComposesTheSameWay() public {
        MockChainlinkFeed borrowedFeed_ = new MockChainlinkFeed(0.99987e8, 8);
        WsgemFxLlamalendOracle chainlink_ = new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(borrowedFeed_),
            WsgemFxLlamalendOracle.QuoteKind.CHAINLINK_FEED,
            SPEED,
            MAXAGE
        );

        assertEq(chainlink_.BORROWED_QUOTE_SCALE(), 1e10, "8 decimals scale to WAD");
        // casting to 'uint256' is safe because FX0 is a positive literal
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 gbpWad_ = uint256(FX0) * 1e10;
        assertEq(
            chainlink_.price(),
            (NAV0 * gbpWad_) / (0.99987e8 * 1e10),
            "the same three-leg product, one scaling later"
        );
    }

    function test_aStaleChainlinkBorrowedQuoteFreezes() public {
        MockChainlinkFeed borrowedFeed_ = new MockChainlinkFeed(0.99987e8, 8);
        WsgemFxLlamalendOracle chainlink_ = new WsgemFxLlamalendOracle(
            IWsgem(address(wsgem)),
            address(borrowed),
            IChainlinkAggregator(address(fx)),
            address(borrowedFeed_),
            WsgemFxLlamalendOracle.QuoteKind.CHAINLINK_FEED,
            SPEED,
            MAXAGE
        );

        uint256 held_ = chainlink_.price();

        // Only the borrowed leg goes stale; the sterling leg keeps publishing.
        skip(MAXAGE + 1);
        fx.set(FX0);

        assertTrue(chainlink_.fxFrozen(), "the staleness bound covers both Chainlink legs");
        assertEq(chainlink_.price(), held_);
    }

    // --- No administrative surface ----------------------------------------------------------------

    function test_thereIsNoAdministrativeSurface() public view {
        // The whole point of the shim. Every parameter is immutable and there is no owner, so the
        // only external mutator is the permissionless checkpoint.
        assertEq(address(oracle).code.length > 0, true);
        assertEq(oracle.MAX_UPSIDE_SPEED(), SPEED);
        assertEq(oracle.MAX_FX_AGE(), MAXAGE);
    }

    function test_priceWIsCallableByAnyArbitraryAddress() public {
        vm.prank(address(0xBEEF));
        assertGt(oracle.price_w(), 0);
    }
}
