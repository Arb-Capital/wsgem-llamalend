// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IAMM
/// @notice The LLAMMA subset a deploy script needs to verify a freshly created market.
/// @dev Note the two similarly named getters, which are easy to confuse:
///        - `price_oracle()` returns the PRICE (uint256), read from the oracle contract.
///        - `price_oracle_contract()` returns the ORACLE ADDRESS.
///      A post-deploy assert wants the second one.
interface IAMM {
    /// @notice The oracle price the AMM is currently working from, scaled by 1e18.
    function price_oracle() external view returns (uint256);

    /// @notice The oracle contract the AMM reads. Repointable by the Configurator.
    function price_oracle_contract() external view returns (address);

    function coins(uint256 i) external view returns (address);

    function A() external view returns (uint256);

    function fee() external view returns (uint256);

    function admin() external view returns (address);

    function active_band() external view returns (int256);

    function get_p() external view returns (uint256);
}
