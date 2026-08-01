// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WstGBPOracleScript, WstGBPMarketScript} from "../script/WstGBP.s.sol";

/// @notice Pins every production constant in the concrete deployment script.
/// @dev This is the tripwire: script/WstGBP.s.sol is the one file in the repo that names a token
///      and fixes the risk parameters, and changing any of it without acknowledging the change
///      here fails CI. The point is not that these particular numbers are correct -- that is what
///      docs/04-parameters.md argues -- but that they cannot move silently.
contract WsgemDeployScriptTest is Test {
    WstGBPOracleScript internal oracleScript;
    WstGBPMarketScript internal marketScript;

    function setUp() public {
        oracleScript = new WstGBPOracleScript();
        marketScript = new WstGBPMarketScript();
    }

    // --- Curve infrastructure --------------------------------------------------------------------

    function test_curveAddresses() public view {
        assertEq(marketScript.FACTORY(), 0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd, "LendFactory");
        assertEq(marketScript.CONFIGURATOR(), 0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC, "Configurator");
    }

    // --- The pair ---------------------------------------------------------------------------------

    function test_tokens() public view {
        assertEq(marketScript.WSGEM(), 0x57C3571f10767E49C9d7b60feb6c67804783B7aE, "collateral");
        assertEq(marketScript.GEM(), 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287, "borrowed");
    }

    // --- Shim parameters ---------------------------------------------------------------------------

    function test_oracleSpeedIsAQuarterPercentPerDay() public view {
        uint256 speed_ = marketScript.MAX_UPSIDE_SPEED();
        assertEq(speed_, uint256(0.0025e18) / 1 days);

        // Restate the intent in the units that matter, so a future edit has to break the claims as
        // well as the number.
        assertApproxEqRel(speed_ * 1 days, 0.0025e18, 1e12, "0.25% per day");

        // Seconds for the ceiling to climb one observed weekly step (6.8 bp). This must be well
        // inside a week, or the limit binds in ordinary operation and the market persistently
        // under-values collateral.
        uint256 absorbSeconds_ = 0.00068e18 / speed_;
        assertLt(absorbSeconds_, 12 hours, "a weekly step must clear well within a week");

        // And it must still be a real limit: a month of allowance stays far below an
        // order-of-magnitude publication.
        assertLt(speed_ * 30 days, 0.1e18, "a month of allowance must stay under 10%");
    }

    function test_rateIntervalsAndGap() public view {
        assertEq(marketScript.RATE_INTERVALS(), 4);
        assertEq(marketScript.MAX_PUBLICATION_GAP(), 10 days);
        assertEq(marketScript.MIN_CHECKPOINT_SPACING(), 1 days);

        // The grace must exceed the publication cadence, or an on-time feed reads as overdue and
        // the reported rate decays during normal operation.
        assertGt(marketScript.MAX_PUBLICATION_GAP(), 7 days, "grace must clear the cadence");

        // The floor must sit well under the cadence, or it would defer genuine publications in
        // normal operation instead of being the inert insurance it is meant to be.
        assertLt(
            marketScript.MIN_CHECKPOINT_SPACING(), 7 days, "the floor must not bind at the cadence"
        );
    }

    // --- Risk parameters ----------------------------------------------------------------------------

    function test_riskParameters() public view {
        assertEq(marketScript.A(), 285);
        assertEq(marketScript.FEE(), 0.002e18);
        assertEq(marketScript.LOAN_DISCOUNT(), 0.013e18);
        assertEq(marketScript.LIQUIDATION_DISCOUNT(), 0.01e18);
        assertEq(marketScript.SUPPLY_LIMIT(), type(uint256).max);
    }

    function test_monetaryPolicyCurve() public view {
        assertEq(marketScript.TARGET_UTILIZATION(), 0.90e18);
        assertEq(marketScript.LOW_RATIO(), 0.5e18);
        assertEq(marketScript.HIGH_RATIO(), 5e18);
        assertEq(marketScript.RATE_SHIFT(), 0);
    }

    // --- The bounds the chain will enforce ------------------------------------------------------------
    //
    // Restated here so a bad parameter set fails in CI rather than reverting mid-broadcast with a
    // Vyper assertion message.

    function test_parametersSatisfyTheFactoryBounds() public view {
        assertGe(marketScript.A(), 2, "MIN_A");
        assertLe(marketScript.A(), 10_000, "MAX_A");
        assertGt(marketScript.LIQUIDATION_DISCOUNT(), 0, "liquidation discount = 0");
        assertLt(marketScript.LOAN_DISCOUNT(), 1e18, "loan discount >= 100%");
        assertGt(marketScript.LOAN_DISCOUNT(), marketScript.LIQUIDATION_DISCOUNT(), "discount ordering");
    }

    function test_feeSatisfiesTheAmmBounds() public view {
        uint256 maxFee_ = (1e18 * 4) / marketScript.A(); // WAD * MIN_TICKS / A
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

    function test_speedIsWithinTheOracleBound() public view {
        // WsgemLlamalendOracle.MAX_UPSIDE_SPEED_LIMIT is 100% per hour.
        assertGt(marketScript.MAX_UPSIDE_SPEED(), 0);
        assertLe(marketScript.MAX_UPSIDE_SPEED(), uint256(1e18) / 1 hours);
    }

    function test_intervalsAndGapAreWithinTheRateCalculatorBounds() public view {
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

    // --- The two scripts must not drift apart -----------------------------------------------------------

    /// @dev The oracle script and the market script carry the same constants through separate
    ///      inheritance chains. If they ever disagree, the market would be created against an
    ///      oracle configured differently from the one that was deployed and observed. Every
    ///      getter in the config is compared -- including the ones the oracle script itself never
    ///      reads -- because "the tripwire covers less than it advertises" is exactly how drift
    ///      starts.
    function test_theOracleAndMarketScriptsAgree() public view {
        assertEq(oracleScript.CHAIN_ID(), marketScript.CHAIN_ID());
        assertEq(oracleScript.FACTORY(), marketScript.FACTORY());
        assertEq(oracleScript.CONFIGURATOR(), marketScript.CONFIGURATOR());
        assertEq(oracleScript.WSGEM(), marketScript.WSGEM());
        assertEq(oracleScript.GEM(), marketScript.GEM());
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

    function test_theConfiguredChainIsMainnet() public view {
        assertEq(marketScript.CHAIN_ID(), 1, "every address in the config is a mainnet address");
    }
}
