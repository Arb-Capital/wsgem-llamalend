// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IVault
/// @notice The Llamalend V2 ERC-4626 lender vault subset used by deploy asserts and integration.
/// @dev The vault carries 1000 virtual shares as inflation-attack defence. They are not minted and
///      are not in `totalSupply`, so a fresh vault does NOT start at a 1:1 asset-to-share ratio --
///      integrators must use `convertToShares`/`convertToAssets` rather than assuming a ratio.
///
///      Withdrawals are bounded by liquidity that is not currently lent out; `maxWithdraw` and
///      `maxRedeem` already account for that.
interface IVault {
    function asset() external view returns (address);

    function amm() external view returns (address);

    function controller() external view returns (address);

    function borrowed_token() external view returns (address);

    function collateral_token() external view returns (address);

    function factory() external view returns (address);

    /// @notice Deposit cap. Zero disables deposits; `type(uint256).max` is unlimited.
    function maxSupply() external view returns (uint256);

    /// @notice Share price scaled to 1e18. Rises as borrower interest accrues.
    function pricePerShare(bool _is_floor) external view returns (uint256);

    function lend_apr() external view returns (uint256);

    function borrow_apr() external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function convertToShares(uint256 _assets) external view returns (uint256);

    function convertToAssets(uint256 _shares) external view returns (uint256);

    function maxDeposit(address _receiver) external view returns (uint256);

    function deposit(uint256 _assets, address _receiver) external returns (uint256);

    function maxWithdraw(address _owner) external view returns (uint256);

    function withdraw(uint256 _assets, address _receiver, address _owner) external returns (uint256);

    function balanceOf(address _owner) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function decimals() external view returns (uint8);
}
