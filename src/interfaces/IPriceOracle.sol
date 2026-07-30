// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IPriceOracle
/// @notice The price oracle interface Llamalend V2 requires. Solidity translation of
///         `curve_stablecoin/interfaces/IPriceOracle.vyi`.
/// @dev The price is one unit of COLLATERAL denominated in the BORROWED token, times 1e18 --
///      irrespective of either token's own decimals.
///
///      Two constraints are enforced by `LendFactory.create` and are easy to get wrong:
///
///        1. `price()` must be non-zero at market creation.
///        2. `price_w()` must return exactly what `price()` returned in the same call. The factory
///           reads `price()` into a local and asserts `price_w() == p`. Any oracle whose write
///           path can return a different number than its read path -- including one that advances
///           an EMA before returning -- fails creation, and would misprice the AMM afterwards.
///
///      The AMM calls `price_w()` on state-changing paths and `price()` on views, so the two must
///      agree within a block by construction, not by luck.
interface IPriceOracle {
    /// @notice Collateral price in borrowed-token terms, scaled by 1e18. View.
    function price() external view returns (uint256);

    /// @notice Same value as `price()`, persisting any smoothing state.
    function price_w() external returns (uint256);
}
