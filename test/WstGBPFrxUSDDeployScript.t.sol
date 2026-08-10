// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {WstGBPFrxUSDOracleScript, WstGBPFrxUSDMarketScript} from "../script/WstGBPFrxUSD.s.sol";
import {WstGBPCrvUSDMarketScript}                           from "../script/WstGBPCrvUSD.s.sol";
import {WstGBPMarketScript}                                 from "../script/WstGBP.s.sol";

import {WsgemFxLlamalendOracle} from "../src/WsgemFxLlamalendOracle.sol";
import {WsgemLlamalendOracle}   from "../src/WsgemLlamalendOracle.sol";
import {IWsgem}                 from "../src/interfaces/IWsgem.sol";
import {IWsgemShimOracle}       from "../src/interfaces/IWsgemShimOracle.sol";
import {IChainlinkAggregator}   from "../src/interfaces/IChainlinkAggregator.sol";

import {MockPip, MockWsgem} from "./mocks/MockWsgem.sol";
import {
    StaticDecimals18,
    StaticGbpUsdFeed,
    StaticStableFeed,
    StaticStableAggregator
} from "./mocks/MockFeeds.sol";

/// @notice Pins every production constant in the wstGBP/frxUSD deployment script.
/// @dev The tripwire `test/WsgemDeployScript.t.sol` is for the first instance. One suite per
///      instance, deliberately: the instances share a base in `script/WstGBPFx.s.sol`, and a suite
///      that read its values through that base would prove only that the base is self-consistent.
///      Every value below is read from THIS instance's script, so an override added here in future
///      is caught here.
contract WstGBPFrxUSDDeployScriptTest is Test {
    WstGBPFrxUSDOracleScript internal oracleScript;
    WstGBPFrxUSDMarketScript internal marketScript;

    function setUp() public {
        oracleScript = new WstGBPFrxUSDOracleScript();
        marketScript = new WstGBPFrxUSDMarketScript();
    }

    // --- Curve infrastructure ------------------------------------------------------------------

    function test_curveAddresses() public view {
        assertEq(marketScript.CHAIN_ID(), 1, "every address in the config is a mainnet address");
        assertEq(marketScript.FACTORY(), 0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd, "LendFactory");
        assertEq(marketScript.CONFIGURATOR(), 0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC, "Configurator");
    }

    // --- The pair ------------------------------------------------------------------------------

    function test_tokens() public view {
        assertEq(marketScript.WSGEM(), 0x57C3571f10767E49C9d7b60feb6c67804783B7aE, "collateral");
        assertEq(marketScript.GEM(), 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287, "gem (tGBP)");
        assertEq(marketScript.BORROWED(), 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29, "frxUSD");
    }

    /// @dev frxUSD is one paste away from the legacy FRAX token, which still exists, still trades,
    ///      and sits meaningfully off a dollar. Both are 18 decimals, so neither the preflight nor
    ///      the oracle constructor separates them.
    function test_theBorrowedTokenIsNotLegacyFrax() public view {
        assertTrue(
            marketScript.BORROWED() != 0x853d955aCEf822Db058eb8505911ED77F175b99e,
            "0x853d955a is FRAX, not frxUSD"
        );
    }

    /// @dev The gem and the borrowed token diverging is the whole premise of this instance. If an
    ///      edit ever made them equal, the oracle would be composing a conversion between a
    ///      currency and itself and nothing else here would notice.
    function test_theGemIsNotTheBorrowedToken() public view {
        assertTrue(marketScript.GEM() != marketScript.BORROWED());
    }

    // --- The conversion legs -------------------------------------------------------------------

    function test_theSterlingLegIsTheChainlinkPushFeed() public view {
        assertEq(marketScript.FX_FEED(), 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5, "GBP/USD");
    }

    /// @dev Chainlink here, where the crvUSD instance uses a Curve aggregator, because there is
    ///      no equivalent Curve contract for frxUSD -- the Curve-native route would be one
    ///      $13.5M pool on a fourteen-minute average divided into the crvUSD aggregator.
    function test_theBorrowedLegIsTheChainlinkFrxUsdFeed() public view {
        assertEq(marketScript.BORROWED_QUOTE(), 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83);
        assertTrue(
            marketScript.BORROWED_QUOTE_KIND() == WsgemFxLlamalendOracle.QuoteKind.CHAINLINK_FEED,
            "a Chainlink round, not a WAD price() view"
        );
    }

    /// @dev Substituting Chainlink's FRAX/USD feed would over-value collateral by the gap between
    ///      the two tokens, because the borrowed token's quote is the divisor.
    function test_theBorrowedLegIsNotTheFraxFeed() public view {
        assertTrue(
            marketScript.BORROWED_QUOTE() != 0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD,
            "0xB9E1E3A9 is FRAX/USD, not frxUSD/USD"
        );
    }

    function test_theStalenessBoundClearsTheHeartbeatWithoutBeingUseless() public view {
        assertEq(marketScript.MAX_FX_AGE(), 30 hours);

        // BOTH legs are Chainlink here, and both are on a 24-hour heartbeat -- so this one bound
        // covers the whole conversion. Tighter and the market freezes in ordinary operation; far
        // looser and the bound catches nothing.
        assertGt(marketScript.MAX_FX_AGE(), 24 hours, "must clear the heartbeat");
        assertLt(marketScript.MAX_FX_AGE(), 48 hours, "must still notice a halted feed within a day");

        // And within the oracle's own accepted range.
        assertGe(marketScript.MAX_FX_AGE(), 1 hours, "MIN_FX_AGE_LIMIT");
        assertLe(marketScript.MAX_FX_AGE(), 7 days, "MAX_FX_AGE_LIMIT");
    }

    // --- Shim and calculator parameters --------------------------------------------------------

    function test_theNavLegIsConfiguredExactlyAsTheFirstInstance() public {
        WstGBPMarketScript first_ = new WstGBPMarketScript();

        // Same wsgem, same feed, same cadence -- so the same rate limit and the same measurement
        // window. A divergence would mean this market throttles a publication differently from the
        // wstGBP/tGBP one for no stated reason.
        assertEq(marketScript.MAX_UPSIDE_SPEED(), first_.MAX_UPSIDE_SPEED());
        assertEq(marketScript.RATE_INTERVALS(), first_.RATE_INTERVALS());
        assertEq(marketScript.MAX_PUBLICATION_GAP(), first_.MAX_PUBLICATION_GAP());
        assertEq(marketScript.MIN_CHECKPOINT_SPACING(), first_.MIN_CHECKPOINT_SPACING());
    }

    function test_shimAndCalculatorValues() public view {
        assertEq(marketScript.MAX_UPSIDE_SPEED(), uint256(0.0025e18) / 1 days, "0.25% per day");
        assertEq(marketScript.RATE_INTERVALS(), 4);
        assertEq(marketScript.MAX_PUBLICATION_GAP(), 10 days);
        assertEq(marketScript.MIN_CHECKPOINT_SPACING(), 1 days);
    }

    // --- Risk parameters -----------------------------------------------------------------------

    function test_riskParameters() public view {
        assertEq(marketScript.A(), 180, "svZCHF/crvUSD's A");
        assertEq(marketScript.FEE(), 0.0005e18, "svZCHF/crvUSD's fee");
        assertEq(marketScript.LOAN_DISCOUNT(), 0.05e18, "svZCHF/crvUSD's 4.3% widened by 70 bp");
        assertEq(marketScript.LIQUIDATION_DISCOUNT(), 0.023e18, "svZCHF/crvUSD's, unchanged");
        assertEq(marketScript.SUPPLY_LIMIT(), type(uint256).max);
    }

    /// @dev The first instance's set is for two assets that track each other. Reusing it against a
    ///      currency pair would leave borrowers permanently in soft liquidation, so the two sets
    ///      must not converge by accident.
    function test_theRiskSetIsWiderThanTheSameCurrencyInstance() public {
        WstGBPMarketScript first_ = new WstGBPMarketScript();

        assertLt(marketScript.A(), first_.A(), "wider bands");
        assertGt(marketScript.LOAN_DISCOUNT(), first_.LOAN_DISCOUNT(), "more room before opening");
        assertGt(
            marketScript.LIQUIDATION_DISCOUNT(),
            first_.LIQUIDATION_DISCOUNT(),
            "more room before hard liquidation"
        );
    }

    function test_monetaryPolicyCurve() public view {
        assertEq(marketScript.TARGET_UTILIZATION(), 0.90e18);
        assertEq(marketScript.LOW_RATIO(), 0.5e18);
        assertEq(marketScript.HIGH_RATIO(), 5e18);
        assertEq(marketScript.RATE_SHIFT(), 0);
    }

    // --- The bounds the chain will enforce -----------------------------------------------------
    //
    // Restated here so a bad parameter set fails in CI rather than reverting mid-broadcast with a
    // Vyper assertion message.

    function test_parametersSatisfyTheFactoryBounds() public view {
        assertGe(marketScript.A(), 2, "MIN_A");
        assertLe(marketScript.A(), 10_000, "MAX_A");
        assertGt(marketScript.LIQUIDATION_DISCOUNT(), 0, "liquidation discount = 0");
        assertLt(marketScript.LOAN_DISCOUNT(), 1e18, "loan discount >= 100%");
        assertGt(
            marketScript.LOAN_DISCOUNT(), marketScript.LIQUIDATION_DISCOUNT(), "discount ordering"
        );
    }

    function test_feeSatisfiesTheAmmBounds() public view {
        uint256 maxFee_ = (1e18 * 4) / marketScript.A();
        if (maxFee_ > 1e17) maxFee_ = 1e17;

        assertGe(marketScript.FEE(), 1e6, "MIN_FEE");
        assertLe(marketScript.FEE(), maxFee_, "MAX_FEE for this A");
    }

    function test_curveParametersSatisfyTheMonetaryPolicyBounds() public view {
        assertGe(marketScript.TARGET_UTILIZATION(), 1e16, "MIN_TARGET_UTIL");
        assertLe(marketScript.TARGET_UTILIZATION(), 99e16, "MAX_TARGET_UTIL");
        assertGe(marketScript.LOW_RATIO(), 1e16, "MIN_LOW_RATIO");
        assertLe(marketScript.HIGH_RATIO(), 100e18, "MAX_HIGH_RATIO");
        assertLe(marketScript.RATE_SHIFT(), 100e18, "MAX_RATE_SHIFT");
    }

    function test_speedAndWindowAreWithinTheShimBounds() public view {
        assertGt(marketScript.MAX_UPSIDE_SPEED(), 0);
        assertLe(marketScript.MAX_UPSIDE_SPEED(), uint256(1e18) / 1 hours, "100% per hour");

        assertGe(marketScript.RATE_INTERVALS(), 2, "MIN_INTERVALS");
        assertLe(marketScript.RATE_INTERVALS(), 7, "SLOTS - 1");
        assertGe(marketScript.MAX_PUBLICATION_GAP(), 1 days);
        assertLe(marketScript.MAX_PUBLICATION_GAP(), 90 days);
        assertLt(
            marketScript.MIN_CHECKPOINT_SPACING(),
            marketScript.MAX_PUBLICATION_GAP(),
            "spacing below the gap"
        );
    }

    // --- The two scripts must not drift apart --------------------------------------------------

    /// @dev The oracle script and the market script carry the same constants through separate
    ///      inheritance chains. If they ever disagree, the market would be created against an
    ///      oracle configured differently from the one deployed and observed.
    function test_theOracleAndMarketScriptsAgree() public view {
        assertEq(oracleScript.CHAIN_ID(), marketScript.CHAIN_ID());
        assertEq(oracleScript.FACTORY(), marketScript.FACTORY());
        assertEq(oracleScript.CONFIGURATOR(), marketScript.CONFIGURATOR());
        assertEq(oracleScript.WSGEM(), marketScript.WSGEM());
        assertEq(oracleScript.GEM(), marketScript.GEM());
        assertEq(oracleScript.BORROWED(), marketScript.BORROWED());
        assertEq(oracleScript.FX_FEED(), marketScript.FX_FEED());
        assertEq(oracleScript.BORROWED_QUOTE(), marketScript.BORROWED_QUOTE());
        assertTrue(oracleScript.BORROWED_QUOTE_KIND() == marketScript.BORROWED_QUOTE_KIND());
        assertEq(oracleScript.MAX_FX_AGE(), marketScript.MAX_FX_AGE());
        assertEq(oracleScript.MAX_UPSIDE_SPEED(), marketScript.MAX_UPSIDE_SPEED());
        assertEq(oracleScript.RATE_INTERVALS(), marketScript.RATE_INTERVALS());
        assertEq(oracleScript.MAX_PUBLICATION_GAP(), marketScript.MAX_PUBLICATION_GAP());
        assertEq(oracleScript.MIN_CHECKPOINT_SPACING(), marketScript.MIN_CHECKPOINT_SPACING());
        assertEq(oracleScript.A(), marketScript.A());
        assertEq(oracleScript.FEE(), marketScript.FEE());
        assertEq(oracleScript.LOAN_DISCOUNT(), marketScript.LOAN_DISCOUNT());
        assertEq(oracleScript.LIQUIDATION_DISCOUNT(), marketScript.LIQUIDATION_DISCOUNT());
        assertEq(oracleScript.SUPPLY_LIMIT(), marketScript.SUPPLY_LIMIT());
        assertEq(oracleScript.TARGET_UTILIZATION(), marketScript.TARGET_UTILIZATION());
        assertEq(oracleScript.LOW_RATIO(), marketScript.LOW_RATIO());
        assertEq(oracleScript.HIGH_RATIO(), marketScript.HIGH_RATIO());
        assertEq(oracleScript.RATE_SHIFT(), marketScript.RATE_SHIFT());
    }
}

/// @notice Exposes this instance's oracle validation so the wrong-oracle cases can be tested.
contract FrxUSDValidationHarness is WstGBPFrxUSDMarketScript {
    function assertOracle(address oracle_) external {
        _assertOracle(IWsgemShimOracle(oracle_));
    }
}

/// @notice The failure nothing on-chain can catch: an oracle that is live, healthy, internally
///         consistent, and built for a different market.
/// @dev Every wstGBP instance shares a wsgem, a gem, a pip and an upside speed, so the shared
///      `_assertOracle` wiring checks pass for all of them against any of them. `WSGEM_ORACLE` is a
///      single environment variable serving every instance. This suite is the reason a mistake
///      there stops at the preflight instead of producing a market priced in the wrong currency.
///
///      The sibling instance's script IS imported here, and only here: the hazard is specifically
///      confusing these two markets, and a test that invented a hypothetical foreign oracle would
///      be testing something weaker than the thing that will actually go wrong.
///
///      Runs against stand-ins etched at the production addresses rather than against mainnet, so
///      it is part of `make test`: the confusion is a property of the configuration, not of live
///      state. The stand-ins keep every answer in code because `vm.etch` copies code, not storage.
contract WstGBPFrxUSDOracleValidationTest is Test {
    uint256 internal constant SPEED  = uint256(0.0025e18) / 1 days;
    uint256 internal constant MAXAGE = 30 hours;

    MockPip internal pip;

    FrxUSDValidationHarness  internal harness;
    WstGBPCrvUSDMarketScript internal sibling;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip = new MockPip(1.05e18);

        harness = new FrxUSDValidationHarness();
        sibling = new WstGBPCrvUSDMarketScript();

        // The scripts' addresses are compile-time constants, so the stand-ins are moved to them
        // rather than the other way around. The wsgem is built first with its immutables already
        // pointing at this instance's gem and at the shared pip, then etched -- immutables live in
        // code, so they survive the copy.
        MockWsgem template_ = new MockWsgem(harness.GEM(), address(pip), 18);
        vm.etch(harness.WSGEM(), address(template_).code);
        vm.etch(harness.GEM(), type(StaticDecimals18).runtimeCode);
        vm.etch(harness.FX_FEED(), type(StaticGbpUsdFeed).runtimeCode);

        vm.etch(harness.BORROWED(), type(StaticDecimals18).runtimeCode);
        vm.etch(harness.BORROWED_QUOTE(), type(StaticStableFeed).runtimeCode);

        // And the sibling's two, so an oracle wired for it can actually be built.
        vm.etch(sibling.BORROWED(), type(StaticDecimals18).runtimeCode);
        vm.etch(sibling.BORROWED_QUOTE(), type(StaticStableAggregator).runtimeCode);
    }

    function _oracle(address borrowed_, address quote_, WsgemFxLlamalendOracle.QuoteKind kind_)
        internal
        returns (WsgemFxLlamalendOracle)
    {
        return new WsgemFxLlamalendOracle(
            IWsgem(harness.WSGEM()),
            borrowed_,
            IChainlinkAggregator(harness.FX_FEED()),
            quote_,
            kind_,
            SPEED,
            MAXAGE
        );
    }

    function test_thisInstanceAcceptsItsOwnOracle() public {
        harness.assertOracle(
            address(_oracle(harness.BORROWED(), harness.BORROWED_QUOTE(), harness.BORROWED_QUOTE_KIND()))
        );
    }

    /// @dev The wstGBP/tGBP shim has no `BORROWED()`, so the call reverts rather than returning
    ///      something plausible -- which is exactly the discriminator the check relies on. Every
    ///      shared wiring check passes first: it is a completely healthy oracle for another market.
    function test_theSameCurrencyOracleIsRejected() public {
        WsgemLlamalendOracle plain_ = new WsgemLlamalendOracle(IWsgem(harness.WSGEM()), SPEED);

        assertEq(address(plain_.WSGEM()), harness.WSGEM(), "it passes the shared wiring checks");
        assertEq(plain_.GEM(), harness.GEM());
        assertFalse(plain_.frozen());
        assertGt(plain_.price(), 0);

        vm.expectRevert();
        harness.assertOracle(address(plain_));
    }

    function test_theCrvUsdInstancesOracleIsRejected() public {
        WsgemFxLlamalendOracle wrong_ = _oracle(
            sibling.BORROWED(), sibling.BORROWED_QUOTE(), sibling.BORROWED_QUOTE_KIND()
        );

        vm.expectRevert(bytes("oracle: borrowed mismatch"));
        harness.assertOracle(address(wrong_));
    }

    /// @dev The subtler half: right borrowed token, wrong source for its price. Nothing about the
    ///      market's tokens distinguishes these two, so only the wiring assertion does.
    function test_anOracleWithTheRightTokenButTheWrongQuoteSourceIsRejected() public {
        address strayFeed_ = address(0xA66);
        vm.etch(strayFeed_, type(StaticStableFeed).runtimeCode);

        WsgemFxLlamalendOracle wrong_ = _oracle(
            harness.BORROWED(), strayFeed_, WsgemFxLlamalendOracle.QuoteKind.CHAINLINK_FEED
        );

        vm.expectRevert(bytes("oracle: borrowed quote mismatch"));
        harness.assertOracle(address(wrong_));
    }

    function test_aFrozenOracleIsRejected() public {
        WsgemFxLlamalendOracle o_ =
            _oracle(harness.BORROWED(), harness.BORROWED_QUOTE(), harness.BORROWED_QUOTE_KIND());

        pip.poke(0);

        vm.expectRevert(bytes("oracle: feed is frozen -- refusing to build on a held price"));
        harness.assertOracle(address(o_));
    }
}
