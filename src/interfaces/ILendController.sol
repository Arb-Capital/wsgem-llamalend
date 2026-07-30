// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title ILendController
/// @notice The Llamalend V2 Controller subset a deploy script and its tests need. Merged from the
///         upstream `IController.vyi` and `ILendController.vyi`.
/// @dev `borrow_cap()` reads zero on a freshly created market. Until a Curve DAO vote calls
///      `Configurator.set_borrow_cap`, `create_loan` reverts and the market is inert.
interface ILendController {
    function amm() external view returns (address);

    function vault() external view returns (address);

    function factory() external view returns (address);

    function configurator() external view returns (address);

    function monetary_policy() external view returns (address);

    function collateral_token() external view returns (address);

    function borrowed_token() external view returns (address);

    function loan_discount() external view returns (uint256);

    function liquidation_discount() external view returns (uint256);

    /// @notice Zero on a fresh market. See the contract-level note.
    function borrow_cap() external view returns (uint256);

    function admin_percentage() external view returns (uint256);

    function total_debt() external view returns (uint256);

    function save_rate() external;

    function create_loan(
        uint256 collateral,
        uint256 debt,
        uint256 N,
        address _for,
        address callbacker,
        bytes calldata data
    ) external;

    /// @dev Vyper default arguments generate one selector per prefix; this is the base form of
    ///      `repay(_d_debt, _for, max_active_band, callbacker, calldata, shrink)`. Passing a
    ///      `_d_debt` at or above the outstanding debt repays in full.
    function repay(uint256 _d_debt) external;

    function borrow_more(
        uint256 collateral,
        uint256 d_debt,
        address _for,
        address callbacker,
        bytes calldata data
    ) external;

    function add_collateral(uint256 collateral, address _for) external;

    function remove_collateral(uint256 collateral, address _for) external;

    /// @dev Base form of `liquidate(user, min_x, _frac, callbacker, calldata)`. `_frac` is the
    ///      fraction of the position to close, WAD-scaled; `1e18` closes it whole.
    function liquidate(address user, uint256 min_x, uint256 _frac) external;

    function tokens_to_liquidate(address user, uint256 frac) external view returns (uint256);

    function health(address user, bool full) external view returns (int256);

    function max_borrowable(uint256 _d_collateral, uint256 _N, address _user) external view returns (uint256);

    function debt(address user) external view returns (uint256);

    function loan_exists(address user) external view returns (bool);

    /// @notice `[collateral_in_amm, borrowed_in_amm, debt, N]`.
    function user_state(address user) external view returns (uint256[4] memory);

    /// @dev One of the six V2 per-operation health previews; the others follow the same shape.
    function create_loan_health_preview(
        uint256 collateral,
        uint256 debt,
        uint256 N,
        address _for,
        bool full
    ) external view returns (int256);
}
