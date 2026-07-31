// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WsgemOracleScript, WsgemMarketScript} from "./WsgemLlamalendDeploy.s.sol";

/// @title WstGBPConstants
/// @notice The concrete wstGBP/tGBP deployment. This is the only file in the repo that names a
///         token or pins an address.
/// @dev To list a future wsgem: copy this file, change the constants, done. No contract changes
///      and no edits to WsgemLlamalendDeploy.s.sol. If a new wsgem cannot be expressed by
///      overriding these getters, that is a gap in the generic base -- fix it there.
///
///      Every value here is asserted by test/WsgemDeployScript.t.sol, so changing one without
///      acknowledging it in the test suite fails CI.
abstract contract WstGBPConstants {
    // --- The pair ------------------------------------------------------------------------------
    //
    // Collateral is the wsgem, borrowed is the gem: the looping direction, where a borrower posts
    // the yield-bearing wrapper and borrows the underlying. Both are 18 decimals, which is what
    // makes the wrapper's WAD redemption quote directly usable as Llamalend's
    // collateral-in-borrowed price.

    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant TGBP   = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    // --- Oracle shim ---------------------------------------------------------------------------

    /// @dev 0.25% per day, sized against the observed cadence rather than a rule of thumb: the NAV
    ///      rises about 6.8 basis points per week (~3.5% APR). The ceiling climbs ~1.04 bp/hour, so
    ///      an ordinary weekly step is absorbed in roughly 6.5 hours and the limit is identical to
    ///      the feed for the other 161 hours -- a time-averaged under-report of about 0.11 bp
    ///      (measured: test_aYearOfNormalOperationCostsAboutATenthOfABasisPoint), against a
    ///      100 bp liquidation discount.
    ///
    ///      What it buys at that price: a mistaken or hostile publication of 2x takes ~9 months to
    ///      propagate and 10x takes ~2.5 years, which is the window in which the borrow cap can be
    ///      set to zero. The realistic failure it guards is an operational one -- a decimals slip
    ///      or a units error in whatever assembles the NAV off-chain -- not market manipulation:
    ///      the NAV is administered, not traded, so there is no pool to manipulate. Nor is it
    ///      frontrunning protection; a 25 bp redemption spread already dominates a 6.8 bp step.
    ///
    ///      Note this guards only the upside. A mistaken publication downward reaches the market in
    ///      one block by design -- see docs/07-operations.md.
    ///
    ///      The explicit `uint256` keeps this integer division rather than a rational literal.
    uint256 internal constant MAX_UPSIDE_SPEED_WSTGBP = uint256(0.0025e18) / 1 days;

    // --- Rate calculator -----------------------------------------------------------------------

    /// @dev Four publication intervals, about a month. Anchoring the measurement on publications
    ///      rather than on a wall clock is what makes a window this short safe -- a partial
    ///      interval never enters the calculation, so it cannot sawtooth.
    ///
    ///      The underlying yield tracks a policy rate that moves in steps, so a longer window is
    ///      not conservatism but lag: after a cut it would keep reporting the old, higher yield and
    ///      borrowers would pay above what their collateral earns for the length of the window.
    ///      Four tracks a step change within a month while still dividing endpoint timing jitter by
    ///      four.
    uint256 internal constant RATE_INTERVALS_WSTGBP = 4;

    /// @dev Ten days against a weekly cadence: one late publication is tolerated without the
    ///      reported rate moving at all. Past this the measurement denominator grows with the wall
    ///      clock, so an abandoned feed decays toward zero rather than holding its last reading.
    uint256 internal constant MAX_PUBLICATION_GAP_WSTGBP = 10 days;

    // --- Risk parameters -----------------------------------------------------------------------
    //
    // Starting point taken from Curve's own stable/stable reference market (sDOLA/crvUSD, market 0
    // on the V2 mainnet factory), which is the closest published analogue: a yield-bearing wrapper
    // against a like-kind asset. Review before broadcast -- see docs/04-parameters.md.

    /// @dev Band width is roughly 1/A, so 285 gives about 35 basis points per band. Appropriate
    ///      where the two assets track each other and the ratio drifts slowly upward.
    uint256 internal constant A_WSTGBP = 285;

    /// @dev 0.2%. The AMM caps this at min(1e18 * 4 / A, 10%) = about 1.40% at A = 285.
    uint256 internal constant FEE_WSTGBP = 0.002e18;

    uint256 internal constant LOAN_DISCOUNT_WSTGBP        = 0.013e18; // 1.3%
    uint256 internal constant LIQUIDATION_DISCOUNT_WSTGBP = 0.01e18;  // 1%

    /// @dev Unlimited vault deposits. This is not the borrow cap -- that is separate, starts at
    ///      zero, and only a Curve DAO vote can lift it.
    uint256 internal constant SUPPLY_LIMIT_WSTGBP = type(uint256).max;

    // --- Monetary policy curve -------------------------------------------------------------------

    uint256 internal constant TARGET_UTILIZATION_WSTGBP = 0.90e18;
    uint256 internal constant LOW_RATIO_WSTGBP          = 0.5e18; // 0.5x base at 0% utilization
    uint256 internal constant HIGH_RATIO_WSTGBP         = 5e18;   // 5x base at 100% utilization
    uint256 internal constant RATE_SHIFT_WSTGBP         = 0;
}

/// @title WstGBPOracleScript
/// @notice Deploys the wstGBP/tGBP price oracle shim on its own.
/// @dev forge script script/WstGBP.s.sol:WstGBPOracleScript --rpc-url $ETH_RPC_URL \
///        --sender $ETH_FROM --keystore $ETH_KEYSTORE --broadcast --verify
///      or `make oracle-deploy`. Run `make oracle-dry` first.
contract WstGBPOracleScript is WsgemOracleScript, WstGBPConstants {
    function WSGEM() public pure override returns (address) {
        return WSTGBP;
    }

    function GEM() public pure override returns (address) {
        return TGBP;
    }

    function MAX_UPSIDE_SPEED() public pure override returns (uint256) {
        return MAX_UPSIDE_SPEED_WSTGBP;
    }

    function RATE_INTERVALS() public pure override returns (uint256) {
        return RATE_INTERVALS_WSTGBP;
    }

    function MAX_PUBLICATION_GAP() public pure override returns (uint256) {
        return MAX_PUBLICATION_GAP_WSTGBP;
    }

    function A() public pure override returns (uint256) {
        return A_WSTGBP;
    }

    function FEE() public pure override returns (uint256) {
        return FEE_WSTGBP;
    }

    function LOAN_DISCOUNT() public pure override returns (uint256) {
        return LOAN_DISCOUNT_WSTGBP;
    }

    function LIQUIDATION_DISCOUNT() public pure override returns (uint256) {
        return LIQUIDATION_DISCOUNT_WSTGBP;
    }

    function SUPPLY_LIMIT() public pure override returns (uint256) {
        return SUPPLY_LIMIT_WSTGBP;
    }

    function TARGET_UTILIZATION() public pure override returns (uint256) {
        return TARGET_UTILIZATION_WSTGBP;
    }

    function LOW_RATIO() public pure override returns (uint256) {
        return LOW_RATIO_WSTGBP;
    }

    function HIGH_RATIO() public pure override returns (uint256) {
        return HIGH_RATIO_WSTGBP;
    }

    function RATE_SHIFT() public pure override returns (uint256) {
        return RATE_SHIFT_WSTGBP;
    }
}

/// @title WstGBPMarketScript
/// @notice Deploys the rate calculator and monetary policy, then creates the wstGBP/tGBP Llamalend
///         V2 market.
/// @dev forge script script/WstGBP.s.sol:WstGBPMarketScript --rpc-url $ETH_RPC_URL \
///        --sender $ETH_FROM --keystore $ETH_KEYSTORE --broadcast --verify
///      or `make market-deploy`. Run `make market-dry` first.
///
///      Set WSGEM_ORACLE to reuse the oracle from WstGBPOracleScript rather than deploying a
///      second one. The resulting market has a zero borrow cap until a Curve DAO vote lifts it.
contract WstGBPMarketScript is WsgemMarketScript, WstGBPConstants {
    function WSGEM() public pure override returns (address) {
        return WSTGBP;
    }

    function GEM() public pure override returns (address) {
        return TGBP;
    }

    function MAX_UPSIDE_SPEED() public pure override returns (uint256) {
        return MAX_UPSIDE_SPEED_WSTGBP;
    }

    function RATE_INTERVALS() public pure override returns (uint256) {
        return RATE_INTERVALS_WSTGBP;
    }

    function MAX_PUBLICATION_GAP() public pure override returns (uint256) {
        return MAX_PUBLICATION_GAP_WSTGBP;
    }

    function A() public pure override returns (uint256) {
        return A_WSTGBP;
    }

    function FEE() public pure override returns (uint256) {
        return FEE_WSTGBP;
    }

    function LOAN_DISCOUNT() public pure override returns (uint256) {
        return LOAN_DISCOUNT_WSTGBP;
    }

    function LIQUIDATION_DISCOUNT() public pure override returns (uint256) {
        return LIQUIDATION_DISCOUNT_WSTGBP;
    }

    function SUPPLY_LIMIT() public pure override returns (uint256) {
        return SUPPLY_LIMIT_WSTGBP;
    }

    function TARGET_UTILIZATION() public pure override returns (uint256) {
        return TARGET_UTILIZATION_WSTGBP;
    }

    function LOW_RATIO() public pure override returns (uint256) {
        return LOW_RATIO_WSTGBP;
    }

    function HIGH_RATIO() public pure override returns (uint256) {
        return HIGH_RATIO_WSTGBP;
    }

    function RATE_SHIFT() public pure override returns (uint256) {
        return RATE_SHIFT_WSTGBP;
    }
}
