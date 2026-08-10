// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IChainlinkAggregator
/// @notice The subset of Chainlink's `AggregatorV3Interface` a shim needs: the latest answer, when
///         it was written, and the scale it is written in.
/// @dev The address consumers hold is an `EACAggregatorProxy`, not the aggregator itself -- the
///      proxy is repointable by Chainlink at a phase change, which is how a feed is upgraded
///      without consumers moving. A shim therefore reads the proxy and must not cache anything the
///      proxy can change underneath it except `decimals()`, which is fixed for the life of a feed.
///
///      Unlike a wsgem's `pip`, this feed DOES carry a publication time, so a staleness bound is
///      possible here and is the only defence against a halted OCR round. `answeredInRound` and
///      `startedAt` are deliberately omitted: the first is meaningless on modern OCR feeds, and the
///      second reports when the round opened rather than when the answer landed.
///
///      GBP/USD on Ethereum mainnet (`0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5`) answers in 8
///      decimals on a 24-hour heartbeat, with deviation rounds landing far more often -- the
///      threshold is 0.15%. Note that is a TRIGGER and not a bound: it says when a round is
///      submitted, not how far the answer may move between rounds, so a fast market delivers a
///      single round several times larger. Nothing here caps a step. It publishes through weekends,
///      so a staleness bound needs no foreign-exchange market-hours carve-out.
interface IChainlinkAggregator {
    /// @notice The latest round. Only `answer` and `updatedAt` are load-bearing here.
    /// @dev `answer` is signed and CAN be negative or zero on a broken feed; callers must reject
    ///      anything that is not strictly positive rather than casting blind.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice The number of decimals `answer` is scaled by. Fixed for the life of the feed.
    function decimals() external view returns (uint8);
}
