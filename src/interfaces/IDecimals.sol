// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IDecimals
/// @notice The one ERC-20 view a shim needs from a token it never holds.
/// @dev Declared as its own file rather than inline so more than one contract can assert the same
///      thing about the same token. `src/WsgemLlamalendOracle.sol` carries its own copy inline; that
///      file is deployed and pinned byte-for-byte by the fork suite, so it is left untouched.
interface IDecimals {
    function decimals() external view returns (uint8);
}
