// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IStablePriceAggregator
/// @notice Curve's crvUSD price aggregator: what one crvUSD is worth in dollar terms, WAD.
/// @dev The deployed instance on Ethereum mainnet is
///      `0x18672b1b0c623a30089A280Ed9256379fb0E4E62`. It is a plain Vyper contract, not a proxy,
///      and it derives its answer from the exponential moving averages of the Curve pools pairing
///      crvUSD against major dollar stablecoins, weighted by pool size. There is no heartbeat and
///      no publication time: the answer moves with trades, so it cannot go stale in the sense a
///      push feed can, and there is nothing to bound the age of.
///
///      Two consequences worth stating plainly. First, its notion of "a dollar" is a basket of
///      dollar stablecoins rather than Chainlink's USD, so composing it with a Chainlink feed
///      leaves a small residual basis. Second, its `admin` is the Curve DAO agent
///      `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` -- the same agent that admins the LendFactory
///      -- and that admin can add and remove the price pairs the average is taken over. Reading
///      this contract is therefore a governance dependency, not merely a market one.
///
///      `price_w()` also exists on the aggregator and advances its stored state. It is deliberately
///      NOT in this interface: a Llamalend oracle's `price()` and `price_w()` must return the same
///      number in the same call, and reading a different function on the write path is exactly how
///      that guarantee is lost.
interface IStablePriceAggregator {
    /// @notice The aggregated crvUSD price in WAD dollar terms. View; never advances state.
    function price() external view returns (uint256);
}
