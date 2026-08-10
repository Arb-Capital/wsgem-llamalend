// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @title IWsgemShimOracle
/// @notice The surface every wsgem oracle shim in this repo exposes beyond `IPriceOracle`: the
///         wiring it was built with, and the two failure states an operator has to be able to tell
///         apart from a healthy price.
/// @dev This exists so the deploy scripts and their tests can validate ANY of this repo's oracles
///      through one code path. Deliberately not inherited by either concrete oracle:
///      `WsgemLlamalendOracle` is deployed and pinned byte-for-byte by the fork suite, so its
///      source cannot be touched, and declaring `is IWsgemShimOracle` there would change its
///      metadata hash and therefore its runtime bytecode. Both oracles satisfy this ABI; that they
///      continue to is a test obligation, and `test/WsgemDeployScript.t.sol` carries it.
///
///      `WSGEM` and `PIP` are typed `address` here rather than `IWsgem`/`IPip`. The ABI is
///      identical either way, and a caller comparing addresses should not have to cast.
interface IWsgemShimOracle is IPriceOracle {
    /// @notice The wsgem this oracle prices.
    function WSGEM() external view returns (address);

    /// @notice The gem the wsgem's redemption quote is denominated in. Read from the wsgem.
    /// @dev NOT necessarily the market's borrowed token -- for a cross-currency market it is not.
    function GEM() external view returns (address);

    /// @notice The wsgem's NAV feed, read from the wsgem at construction.
    function PIP() external view returns (address);

    /// @notice Maximum relative increase in the rate-limited leg per second, WAD-scaled.
    function MAX_UPSIDE_SPEED() external view returns (uint256);

    /// @notice The undamped price, in the same terms as `price()`. Zero in either failure state.
    function spotPrice() external view returns (uint256);

    /// @notice Whether a feed is unreadable, so the reported price is frozen at its last value.
    function frozen() external view returns (bool);

    /// @notice Whether the feed is live but the wrapper's redemption quote is zero.
    function quoteIsZero() external view returns (bool);
}
