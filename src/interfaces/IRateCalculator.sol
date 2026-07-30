// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IRateCalculator
/// @notice The external yield-rate source a `HyperbolicDynamicMP` monetary policy follows.
///         Solidity translation of `curve_stablecoin/interfaces/IRateCalculator.vyi`.
/// @dev Returns a rate PER SECOND scaled by 1e18, not an APR. Annualise with
///      `rate * 365 * 86400 / 1e18`.
///
///      The monetary policy reads this defensively: `HyperbolicDynamicMP._target_rate()` calls
///      `rate()` through `raw_call(..., revert_on_failure=False)` and clamps the result into
///      [MIN_TARGET_RATE, MAX_TARGET_RATE] = [317097920, 47564687975] (~1% to ~150% APR). A revert
///      or a nonsense value therefore degrades to the floor rather than propagating -- but an
///      implementation should still not rely on that as its error handling.
interface IRateCalculator {
    /// @notice Current per-second yield rate, scaled by 1e18. View.
    function rate() external view returns (uint256);

    /// @notice Same value as `rate()`, persisting any sampling state.
    function rate_w() external returns (uint256);
}
