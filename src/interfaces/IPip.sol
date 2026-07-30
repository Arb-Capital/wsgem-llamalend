// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IPip
/// @notice The wsgem's oracle price feed.
/// @dev `read()` is a single stored value published by a permissioned poker. There is no
///      `updatedAt` view -- the publication time exists only in the feed's own event -- so no
///      consumer can bound the age of a price on-chain. Any staleness policy has to be built from
///      what a consumer itself observes, not from the feed.
///
///      A paused feed reads zero. That is the one value a Llamalend oracle must never propagate:
///      the factory rejects a zero price at market creation, and an AMM that sees zero mid-market
///      prices every position to nothing.
interface IPip {
    /// @notice The raw NAV in WAD gem-per-wsgem. Zero when paused.
    function read() external view returns (uint256);
}
