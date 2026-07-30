// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IWsgem
/// @notice The subset of a wrapped-staked gem (wsgem) that a Llamalend price oracle and rate
///         calculator need.
/// @dev A wsgem is an ERC-20 wrapper whose value accrues against an underlying `gem`. It does not
///      rebase: the balance is fixed and the NAV rises. `gem`, `pip` and `act` are `immutable` on
///      the wrapper -- set once in its constructor and never repointable -- so a shim may read
///      them once at construction and cache them.
///
///      This is deliberately NOT an ERC-4626 interface. A wsgem has no `asset()`, no
///      `convertToAssets`, and no internal accounting of held assets; the exchange rate is a
///      single value published by the `pip` feed.
interface IWsgem {
    /// @notice The underlying purchase token the wsgem is priced in.
    function gem() external view returns (address);

    /// @notice The oracle price feed. Immutable on the wrapper.
    function pip() external view returns (address);

    /// @notice The market-timing / spread feed. Immutable on the wrapper.
    function act() external view returns (address);

    /// @notice The raw NAV in WAD gem-per-wsgem, un-fee-adjusted. Equals `IPip(pip()).read()`.
    /// @dev Zero means the feed is paused. Callers MUST handle that; it is not an error state the
    ///      wsgem itself signals.
    function navprice() external view returns (uint256);

    /// @notice ERC-20 decimals. Constant 18 on every wsgem to date; shims assert it anyway.
    function decimals() external view returns (uint8);
}
