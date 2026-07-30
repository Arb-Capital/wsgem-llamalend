// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IMonetaryPolicy
/// @notice The whole interface a Llamalend V2 Controller requires of a monetary policy. Solidity
///         translation of `curve_stablecoin/interfaces/IMonetaryPolicy.vyi`.
/// @dev `rate_write` is called by `Controller._save_rate()` on every user operation. Curve's own
///      note on that path: if the monetary policy is stateful, `rate_write` MUST be permissioned,
///      because otherwise anyone can advance its state by calling it directly.
interface IMonetaryPolicy {
    function rate() external view returns (uint256);

    function rate_write() external returns (uint256);
}

/// @title IHyperbolicDynamicMP
/// @notice The Curve monetary policy this repo deploys: a hyperbolic rate curve whose base rate
///         follows an external `IRateCalculator`, intended for like-kind markets where the
///         collateral is a yield-bearing wrapper of the borrowed token.
/// @dev Deployed from vendored initcode -- see script/bytecode/PROVENANCE.md. The constructor is
///      `(controller, rate_calculator, target_utilization, low_ratio, high_ratio, rate_shift)`.
///      CONTROLLER is immutable, which is why the controller address has to be predicted before
///      `LendFactory.create` runs.
interface IHyperbolicDynamicMP is IMonetaryPolicy {
    function CONTROLLER() external view returns (address);

    function RATE_CALCULATOR() external view returns (address);

    /// @notice The per-second base rate read from the rate calculator, clamped to
    ///         [317097920, 47564687975] (~1% to ~150% APR).
    function target_rate() external view returns (uint256);

    /// @notice `target_rate()` annualised.
    function target_apr() external view returns (uint256);
}
