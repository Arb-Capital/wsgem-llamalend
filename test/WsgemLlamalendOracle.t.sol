// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../src/WsgemLlamalendOracle.sol";
import {IWsgem}               from "../src/interfaces/IWsgem.sol";
import {MockPip, MockGem, MockWsgem} from "./mocks/MockWsgem.sol";

contract WsgemLlamalendOracleTest is Test {
    uint256 internal constant WAD   = 1e18;
    uint256 internal constant SPEED = uint256(0.0025e18) / 1 days; // the configured 0.25% per day
    uint256 internal constant NAV0  = 1.05e18;

    MockPip              internal pip;
    MockGem              internal gem;
    MockWsgem            internal wsgem;
    WsgemLlamalendOracle internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip    = new MockPip(NAV0);
        gem    = new MockGem(18);
        wsgem  = new MockWsgem(address(gem), address(pip), 18);
        oracle = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    // --- Construction ------------------------------------------------------------------------

    function test_constructorCachesTheImmutableWiring() public view {
        assertEq(address(oracle.WSGEM()), address(wsgem));
        assertEq(oracle.GEM(), address(gem));
        assertEq(address(oracle.PIP()), address(pip));
        assertEq(oracle.MAX_UPSIDE_SPEED(), SPEED);
    }

    function test_constructorReportsTheLiveNavExactly() public view {
        assertEq(oracle.price(), NAV0, "a fresh oracle must not be rate-limited against itself");
    }

    function test_constructorRejectsAPausedFeed() public {
        pip.poke(0);
        vm.expectRevert(WsgemLlamalendOracle.OraclePaused.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    function test_constructorRejectsAZeroWsgem() public {
        vm.expectRevert(WsgemLlamalendOracle.ZeroAddress.selector);
        new WsgemLlamalendOracle(IWsgem(address(0)), SPEED);
    }

    function test_constructorRejectsAWsgemWithAZeroGem() public {
        MockWsgem noGem_ = new MockWsgem(address(0), address(pip), 18);
        vm.expectRevert(WsgemLlamalendOracle.ZeroAddress.selector);
        new WsgemLlamalendOracle(IWsgem(address(noGem_)), SPEED);
    }

    function test_constructorRejectsAWsgemWithAZeroPip() public {
        MockWsgem noPip_ = new MockWsgem(address(gem), address(0), 18);
        vm.expectRevert(WsgemLlamalendOracle.ZeroAddress.selector);
        new WsgemLlamalendOracle(IWsgem(address(noPip_)), SPEED);
    }

    function test_constructorRejectsANonEighteenDecimalWsgem() public {
        MockWsgem odd_ = new MockWsgem(address(gem), address(pip), 6);
        vm.expectRevert(WsgemLlamalendOracle.UnsupportedDecimals.selector);
        new WsgemLlamalendOracle(IWsgem(address(odd_)), SPEED);
    }

    function test_constructorRejectsANonEighteenDecimalGem() public {
        MockGem   odd_    = new MockGem(6);
        MockWsgem wsgem_  = new MockWsgem(address(odd_), address(pip), 18);
        vm.expectRevert(WsgemLlamalendOracle.UnsupportedDecimals.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem_)), SPEED);
    }

    function test_constructorRejectsAnUnboundedSpeed() public {
        // Read the limit BEFORE arming the cheatcode: expectRevert binds to the next call, and an
        // inline `oracle.MAX_UPSIDE_SPEED_LIMIT()` would be that call.
        uint256 tooHigh_ = oracle.MAX_UPSIDE_SPEED_LIMIT() + 1;

        vm.expectRevert(WsgemLlamalendOracle.SpeedTooHigh.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), tooHigh_);

        vm.expectRevert(WsgemLlamalendOracle.SpeedTooHigh.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), 0);
    }

    function test_constructorAcceptsTheSpeedBoundaries() public {
        WsgemLlamalendOracle slowest_ = new WsgemLlamalendOracle(IWsgem(address(wsgem)), 1);
        assertEq(slowest_.MAX_UPSIDE_SPEED(), 1);

        uint256 limit_ = oracle.MAX_UPSIDE_SPEED_LIMIT();
        WsgemLlamalendOracle fastest_ = new WsgemLlamalendOracle(IWsgem(address(wsgem)), limit_);
        assertEq(fastest_.MAX_UPSIDE_SPEED(), limit_);
    }

    function test_constructorEmitsTheInitialPrice() public {
        vm.expectEmit(true, true, false, true);
        emit PriceUpdated(NAV0, NAV0);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    // --- The factory's own check ---------------------------------------------------------------

    /// @dev `LendFactory.create` reads `price()` into a local and asserts `price_w()` equals it.
    ///      An oracle that advances state before returning fails market creation outright.
    function test_priceAndPriceWAgreeWithinACall() public {
        pip.poke(2e18); // a jump large enough that the rate limit is binding
        skip(3 days);

        uint256 p_ = oracle.price();
        assertEq(oracle.price_w(), p_, "price_w must return exactly what price returned");
    }

    function test_priceIsUnchangedByAPriceWInTheSameBlock() public {
        pip.poke(2e18);
        skip(3 days);

        uint256 before_ = oracle.price();
        oracle.price_w();
        assertEq(oracle.price(), before_, "price_w must not move price within a block");
    }

    // --- Upside rate limit -----------------------------------------------------------------------

    function test_aSmallRiseIsAbsorbedQuickly() public {
        // The observed cadence is ~6.8 bp per week. At 0.25%/day the limit clears that in ~6.5h.
        uint256 target_ = (NAV0 * (WAD + 0.00068e18)) / WAD;
        pip.poke(target_);

        skip(7 hours);
        oracle.price_w();
        assertEq(oracle.price(), target_, "an ordinary weekly step must not be rate-limited for long");
    }

    function test_aLargeRiseIsRateLimited() public {
        pip.poke(NAV0 * 10);

        skip(1 days);
        uint256 p_ = oracle.price();

        // One day of allowance is 0.25%, so the reported price must be about 1.0025x, not 10x.
        assertApproxEqRel(p_, (NAV0 * 10_025) / 10_000, 1e12);
        assertLt(p_, (NAV0 * 10_050) / 10_000, "one day must not buy more than one day of allowance");
    }

    function test_aLargeRiseEventuallyArrives() public {
        pip.poke(NAV0 * 2);

        // Ratchet forward a day at a time. Compounding at 0.25%/day, doubling takes ~278 days.
        for (uint256 i; i < 300; ++i) {
            skip(1 days);
            oracle.price_w();
        }
        assertEq(oracle.price(), NAV0 * 2, "the limit must delay a genuine repricing, not block it");
    }

    function test_allowanceDoesNotAccrueBeyondMaxElapsed() public {
        pip.poke(NAV0 * 100);

        // A market untouched for a year must not accumulate a year of allowance.
        skip(365 days);
        uint256 p_ = oracle.price();

        uint256 ceilingAt7Days_ = NAV0 + (NAV0 * SPEED * 7 days) / WAD;
        assertEq(p_, ceilingAt7Days_, "elapsed time must be capped at MAX_ELAPSED");
    }

    function test_priceWDoesNotBankAllowanceAcrossAFreeze() public {
        // Freeze for a month, then republish far above the last good price. The limit must be
        // measured from the moment the freeze ended, not from before it began.
        pip.poke(0);
        for (uint256 i; i < 30; ++i) {
            skip(1 days);
            oracle.price_w(); // the AMM keeps touching the oracle through a pause
        }

        pip.poke(NAV0 * 10);
        skip(1 days);
        assertApproxEqRel(oracle.price(), (NAV0 * 10_025) / 10_000, 1e12);
    }

    // --- Downside ------------------------------------------------------------------------------

    function test_aFallPassesThroughImmediately() public {
        uint256 lower_ = NAV0 / 2;
        pip.poke(lower_);
        assertEq(oracle.price(), lower_, "under-valuing collateral is the safe direction");
    }

    function test_aFallResetsTheCeiling() public {
        pip.poke(NAV0 / 2);
        oracle.price_w();

        // The ceiling must now grow from the new, lower level rather than the old one.
        skip(1 days);
        assertApproxEqRel(oracle.priceCeiling(), (NAV0 * 10_025) / 20_000, 1e12);
    }

    // --- Freeze ----------------------------------------------------------------------------------

    function test_aPausedFeedFreezesRatherThanReportingZero() public {
        pip.poke(0);
        assertTrue(oracle.frozen());
        assertEq(oracle.price(), NAV0, "zero must never reach Llamalend");
        assertEq(oracle.price_w(), NAV0);
    }

    function test_anUnreadableFeedFreezesToo() public {
        pip.setMode(MockPip.Mode.REVERTING);
        assertEq(oracle.price(), NAV0, "a reverting pip is a pause with a different shape");
        assertEq(oracle.price_w(), NAV0);
    }

    function test_aShortReturnFreezesToo() public {
        // Poke a value the oracle has never reported before breaking the feed, so "froze at the
        // cache" and "decoded the payload anyway" give different answers.
        pip.poke(NAV0 * 2);
        pip.setMode(MockPip.Mode.SHORT_RETURN);
        skip(7 days);
        assertEq(oracle.price(), NAV0, "a short return must freeze, not decode");
        assertTrue(oracle.frozen());
        assertEq(oracle.price_w(), NAV0);
    }

    function test_aLongReturnIsReadAsItsFirstWord() public {
        // A small rise the rate limit clears immediately: if the over-long return were treated as
        // a pause the price would stay at NAV0, so the two behaviours are distinguishable.
        uint256 higher_ = (NAV0 * (WAD + 0.0001e18)) / WAD;
        pip.poke(higher_);
        pip.setMode(MockPip.Mode.LONG_RETURN);
        skip(1 days);
        assertEq(oracle.price(), higher_, "an over-long return decodes to its first word");
        assertFalse(oracle.frozen());
    }

    function test_aGasBombPipIsCappedAndFreezes() public {
        pip.poke(NAV0 * 2); // a value the oracle must NOT report if the bomb is absorbed
        pip.setMode(MockPip.Mode.GAS_BOMB);
        skip(7 days);

        uint256 before_ = gasleft();
        uint256 p_ = oracle.price();
        uint256 used_ = before_ - gasleft();

        assertEq(p_, NAV0, "a gas-burning pip is a pause with a different shape");
        assertTrue(oracle.frozen());
        assertLt(
            used_,
            oracle.PIP_READ_GAS() + 50_000,
            "the read must never forward more than PIP_READ_GAS to the feed"
        );
        assertEq(oracle.price_w(), NAV0);
    }

    function test_aReturndataBombFreezesUnderTheGasCap() public {
        pip.poke(NAV0 * 2);
        pip.setMode(MockPip.Mode.RETURNDATA_BOMB);
        skip(7 days);

        uint256 before_ = gasleft();
        uint256 p_ = oracle.price();
        uint256 used_ = before_ - gasleft();

        assertEq(p_, NAV0, "a payload too large to build under the cap reads as a pause");
        assertTrue(oracle.frozen());
        assertLt(
            used_,
            oracle.PIP_READ_GAS() + 50_000,
            "the caller must never pay for an oversized payload"
        );
        assertEq(oracle.price_w(), NAV0);
    }

    function test_theReadPathSurvivesAGasBombOnABoundedBudget() public {
        // An AMM read arrives with whatever gas the outer transaction has left. With the bomb
        // armed, a 400k budget must still produce a price: the cap leaves the oracle enough to
        // finish after the feed has burned its allowance.
        pip.setMode(MockPip.Mode.GAS_BOMB);
        (bool ok_, bytes memory ret_) =
            address(oracle).staticcall{gas: 400_000}(abi.encodeWithSignature("price()"));
        assertTrue(ok_, "price() must not propagate a feed out-of-gas");
        assertEq(abi.decode(ret_, (uint256)), NAV0);
    }

    function test_freezeHoldsTheLastReportedPriceNotTheLastSpot() public {
        // Reported price lags a jump. When the feed then pauses, the freeze must hold the value
        // this oracle last REPORTED -- not the higher spot it never reported.
        pip.poke(NAV0 * 10);
        skip(1 days);
        uint256 reported_ = oracle.price_w();

        pip.poke(0);
        assertEq(oracle.price(), reported_);
        assertLt(reported_, NAV0 * 10);
    }

    function test_priceIsNeverZeroAcrossAFullPauseCycle() public {
        pip.poke(0);
        for (uint256 i; i < 10; ++i) {
            skip(1 days);
            assertGt(oracle.price(), 0);
            assertGt(oracle.price_w(), 0);
        }
        pip.poke(NAV0);
        assertGt(oracle.price(), 0);
    }

    // --- The redemption quote ----------------------------------------------------------------

    function test_priceIsTheRedemptionQuoteNotTheNav() public {
        // The live wrapper's shape: a 25 bp redemption spread below the NAV.
        wsgem.setFee(0.0025e18);
        uint256 quote_ = (NAV0 * (WAD - 0.0025e18)) / WAD;

        // A spread appearing is a downward move and passes through immediately: the executable
        // floor genuinely dropped.
        assertEq(oracle.price(), quote_, "the oracle reports burncost, not the NAV");
        assertEq(oracle.spotPrice(), quote_);
        oracle.price_w();

        // A spread cut is an upward move, rate-limited like any other.
        wsgem.setFee(0);
        assertEq(oracle.price(), quote_, "a spread cut cannot jump the price");
        skip(26 hours);
        oracle.price_w();
        assertEq(oracle.price(), NAV0, "it arrives at the configured speed");
    }

    function test_constructorCheckpointsTheQuoteNotTheNav() public {
        wsgem.setFee(0.0025e18);
        WsgemLlamalendOracle o_ = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
        assertEq(o_.price(), (NAV0 * (WAD - 0.0025e18)) / WAD);
    }

    function test_constructorRejectsAZeroQuote() public {
        // A live feed with a 100% spread is not a pause, and not a price to build a market on.
        wsgem.setFee(1e18);
        vm.expectRevert(WsgemLlamalendOracle.QuoteIsZero.selector);
        new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    function test_aHundredPercentSpreadReportsOneWeiNotTheOldPrice() public {
        oracle.price_w();

        // The wrapper's settable maximum: the quote is zero while the feed stays live. Freezing
        // here would keep borrowing open against collateral that redemption values at nothing.
        wsgem.setFee(1e18);
        assertEq(oracle.price(), 1, "a live zero quote reports one wei, not the old price");
        assertEq(oracle.price_w(), 1);
        assertFalse(oracle.frozen(), "this is not a pause");
        assertTrue(oracle.quoteIsZero());
        assertEq(oracle.spotPrice(), 0, "the raw quote is truthfully zero");
        assertEq(oracle.cachedPrice(), NAV0, "the floor is never anchored");

        // Restoration recovers from the last real anchor, not from one wei. This is the upside
        // limit's sole exception, and it cannot raise the price above the anchor's own ceiling.
        wsgem.setFee(0.0025e18);
        assertEq(
            oracle.price(),
            (NAV0 * (WAD - 0.0025e18)) / WAD,
            "recovery is from the anchor, not from dust"
        );
        assertFalse(oracle.quoteIsZero());
    }

    function test_constructorAcceptsAGenuineOneWeiQuote() public {
        pip.poke(1);
        WsgemLlamalendOracle o_ = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
        assertEq(o_.price(), 1, "one wei is a price, not the zero-quote state");
        assertFalse(o_.quoteIsZero());
    }

    function test_theZeroQuoteTransitionsAreEventedExactlyOnce() public {
        wsgem.setFee(1e18);
        skip(30 days);

        // Entering the floor is evented once, with the held anchor...
        vm.expectEmit(true, false, false, true, address(oracle));
        emit QuoteZeroed(NAV0);
        oracle.price_w();

        // ...and repeated traffic through the state is silent.
        vm.recordLogs();
        oracle.price_w();
        oracle.price_w();
        assertEq(vm.getRecordedLogs().length, 0, "the state is evented on transition, not per call");

        // Leaving is evented with the price reported on the way out.
        wsgem.setFee(0);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit QuoteRestored(NAV0);
        oracle.price_w();

        // And no allowance banked across the episode.
        pip.poke(NAV0 * 10);
        skip(1 days);
        assertApproxEqRel(
            oracle.price(),
            (NAV0 * 10_025) / 10_000,
            1e12,
            "no allowance may bank across a zero-quote period"
        );
    }

    function test_pausedAndLiveZeroAreDistinctStates() public {
        pip.poke(0);
        assertTrue(oracle.frozen());
        assertFalse(oracle.quoteIsZero());
        assertEq(oracle.price(), NAV0, "a pause holds the last price");

        pip.poke(NAV0);
        wsgem.setFee(1e18);
        assertFalse(oracle.frozen());
        assertTrue(oracle.quoteIsZero());
        assertEq(oracle.price(), 1, "a live zero floors the price instead");
    }

    function test_aPauseAfterAWitnessedZeroQuoteHoldsTheFloor() public {
        // The freeze rule is "hold the last report". If the last report was the one-wei floor,
        // a pause must keep holding the floor -- snapping back to the anchor while the feed is
        // dark would re-value worthless collateral on no information.
        wsgem.setFee(1e18);
        oracle.price_w(); // the floor is witnessed and flagged

        pip.poke(0);
        assertTrue(oracle.frozen());
        assertEq(oracle.price(), 1, "a freeze holds the floor it last reported");
        assertEq(oracle.price_w(), 1);

        // The feed returns healthy: the anchor was kept, so recovery is immediate.
        pip.poke(NAV0);
        wsgem.setFee(0);
        assertEq(oracle.price(), NAV0);
    }

    /// @dev Pins the read ordering. A nonzero quote is NOT taken as proof the feed is live:
    ///      the quote's last hop (`Act.burncost`) sits behind an upgradeable proxy of its own,
    ///      so a broken or hostile Act implementation could quote a price over a paused feed.
    ///      The pip is the sole pause authority -- when it reads dark, a live-looking quote is
    ///      frozen over, never followed and never anchored.
    function test_aDivergingQuoteNeverBypassesThePauseSignal() public {
        wsgem.setQuoteOverride(NAV0 + 0.0001e18); // a quote that no longer reads the pip
        skip(1 days);

        pip.poke(0); // the pause signal
        assertTrue(oracle.frozen(), "a dark NAV is a pause, whatever the quote says");
        assertEq(oracle.price(), NAV0, "the freeze holds the last report");
        assertEq(oracle.price_w(), NAV0);
        assertEq(oracle.cachedPrice(), NAV0, "the diverging quote must never anchor");

        pip.setMode(MockPip.Mode.REVERTING); // an unreadable NAV is the same state
        assertTrue(oracle.frozen());
        assertEq(oracle.price(), NAV0);
    }

    /// @dev The other side of the same hazard: the quote's last hop breaks while the pip stays
    ///      live. An unreadable quote is a pause with a different shape -- the price freezes at
    ///      the last report rather than following a feed that can no longer be valued. Needs its
    ///      own harness: MockWsgem's `burncost` only fails when the pip itself does, so this
    ///      branch is unreachable through it.
    function test_aBrokenQuoteHopOverALiveNavFreezes() public {
        QuoteBreakingWsgem broken_ = new QuoteBreakingWsgem(address(gem), address(pip));
        WsgemLlamalendOracle o_ = new WsgemLlamalendOracle(IWsgem(address(broken_)), SPEED);
        assertEq(o_.price(), NAV0);

        broken_.setBroken(true);
        assertTrue(o_.frozen(), "an unreadable quote over a live NAV is a pause");
        assertFalse(o_.quoteIsZero(), "and not the zero-quote state");
        assertEq(o_.price(), NAV0, "frozen at the last report");
        assertEq(o_.price_w(), NAV0);

        broken_.setBroken(false);
        assertFalse(o_.frozen());
        assertEq(o_.price(), NAV0);
    }

    // --- Events ----------------------------------------------------------------------------------

    event PriceUpdated(uint256 indexed price, uint256 indexed spot);
    event QuoteZeroed(uint256 indexed anchor);
    event QuoteRestored(uint256 indexed price);

    function test_priceWEmitsTheReportedPriceWithTheRawSpotAlongside() public {
        pip.poke(NAV0 * 10);
        skip(1 days);

        // One day of allowance, computed exactly as `_ceiling` does: rate first, then growth.
        uint256 expected_ = NAV0 + (NAV0 * (SPEED * 1 days)) / WAD;

        vm.expectEmit(true, true, false, true, address(oracle));
        emit PriceUpdated(expected_, NAV0 * 10);
        oracle.price_w();
    }

    /// @dev A fall passes through undamped, and it is evented like any other move -- the
    ///      downward emit path, which no other test pins.
    function test_priceWEmitsOnADownwardMove() public {
        uint256 lower_ = NAV0 / 2;
        pip.poke(lower_);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit PriceUpdated(lower_, lower_);
        oracle.price_w();
    }

    function test_priceWDoesNotEmitWhenFlatOrThroughAFreeze() public {
        vm.recordLogs();
        oracle.price_w();
        assertEq(vm.getRecordedLogs().length, 0, "no move, no event");

        pip.poke(0);
        skip(1 days);
        vm.recordLogs();
        oracle.price_w();
        assertEq(vm.getRecordedLogs().length, 0, "a freeze is a report of the same value, not a move");
    }

    // --- Permissionlessness ------------------------------------------------------------------------

    function test_priceWIsCallableByAnyArbitraryAddress() public {
        pip.poke(NAV0 * 10);
        skip(1 days);

        vm.prank(address(0xBEEF));
        uint256 p_ = oracle.price_w();
        assertEq(p_, oracle.price(), "price_w carries no caller privilege of any kind");
    }

    // --- Ownerlessness ---------------------------------------------------------------------------

    /// @dev The whole premise of the shim. If any of these ever resolve, something with an admin
    ///      has been introduced between the feed and the market.
    function test_thereIsNoAdministrativeSurface() public view {
        string[8] memory sigs_ = [
            "owner()",
            "admin()",
            "wards(address)",
            "rely(address)",
            "deny(address)",
            "setPrice(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs_.length; ++i) {
            (bool ok_,) = address(oracle).staticcall(abi.encodeWithSignature(sigs_[i], address(0)));
            assertFalse(ok_, sigs_[i]);
        }
    }

    // --- Fuzz --------------------------------------------------------------------------------------

    function testFuzz_reportedPriceNeverExceedsSpot(uint128 nav_, uint32 dt_) public {
        vm.assume(nav_ > 0);
        pip.poke(nav_);
        skip(dt_);
        assertLe(oracle.price(), nav_, "the shim may under-report, never over-report");
    }

    function testFuzz_reportedPriceIsNeverZero(uint128 nav_, uint32 dt_) public {
        pip.poke(nav_);
        skip(dt_);
        assertGt(oracle.price(), 0);
        assertGt(oracle.price_w(), 0);
    }

    function testFuzz_priceAndPriceWAlwaysAgree(uint128 nav_, uint32 dt_) public {
        pip.poke(nav_);
        skip(dt_);
        assertEq(oracle.price_w(), oracle.price());
    }

    /// @dev Unlike the single-step fuzz above, this one persists a checkpoint between the two
    ///      pokes, so the second step is measured against a ratcheted cache rather than the
    ///      constructor's.
    function testFuzz_reportedPriceNeverExceedsSpotAcrossSteps(
        uint128 nav1_,
        uint128 nav2_,
        uint32 dt1_,
        uint32 dt2_
    ) public {
        vm.assume(nav1_ > 0 && nav2_ > 0);

        pip.poke(nav1_);
        skip(dt1_);
        oracle.price_w();

        pip.poke(nav2_);
        skip(dt2_);
        assertLe(oracle.price(), nav2_, "no checkpoint history may push the report past spot");
        assertEq(oracle.price_w(), oracle.price());
    }
}

/// @notice A wrapper whose quote hop can be broken independently of the pip -- the shape of an
///         Act proxy upgrade that reverts while the NAV stays live.
/// @dev MockWsgem cannot reach this state: its `burncost` only fails when the pip itself does,
///      and the pip read short-circuits `_spot` first.
contract QuoteBreakingWsgem {
    address public immutable gem;
    address public immutable pip;
    uint8 public constant decimals = 18;

    bool public broken;

    constructor(address gem_, address pip_) {
        gem = gem_;
        pip = pip_;
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function burncost() external view returns (uint256) {
        require(!broken, "act: unreadable");
        return MockPip(pip).read();
    }
}
