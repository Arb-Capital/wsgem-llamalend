// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IConfigurator
/// @notice Llamalend V2 `Configurator` -- the permissioned administration surface for a market.
/// @dev The per-market setters are gated on the Configurator's default admin (the Curve DAO on
///      mainnet) or, if one is set, that market's custom admin. `set_custom_admin` and
///      `set_owner` are callable by the default admin only. None of it is callable by a market
///      deployer.
///
///      This is the complete Configurator surface. It is not the whole privileged surface of a
///      deployed market: `factory.admin()` holds further levers outside this contract -- vault
///      `set_max_supply`, policy `set_parameters`, the factory's fee receivers and ownership --
///      see docs/00-architecture.md and docs/07-operations.md. The Configurator's levers belong
///      in the trust model of anything integrating a market -- in particular `set_price_oracle`,
///      which can repoint the market away from the shim in this repo, and `set_monetary_policy`.
interface IConfigurator {
    /// @notice Lift a market's borrow cap. Markets are created with a cap of zero, so this is the
    ///         call that actually opens borrowing.
    function set_borrow_cap(address _controller, uint256 _borrow_cap) external;

    /// @notice Set the administrator's share of interest, WAD-scaled.
    function set_admin_percentage(address _controller, uint256 _admin_percentage) external;

    /// @notice Repoint the market's price oracle, subject to a maximum deviation from the current
    ///         reported price.
    function set_price_oracle(address _controller, address _price_oracle, uint256 _max_deviation) external;

    function set_monetary_policy(address _controller, address _monetary_policy) external;

    function set_borrowing_discounts(address _controller, uint256 _loan_discount, uint256 _liquidation_discount)
        external;

    function set_amm_fee(address _controller, uint256 _fee) external;

    /// @notice Set this controller's custom-admin slot. Default-admin-only.
    /// @dev The custom admin becomes authorized for the per-market setters alongside the default
    ///      admin — a fourth principal for that market. It cannot call this function or
    ///      `set_owner`.
    function set_custom_admin(address _controller, address _admin) external;

    /// @notice Replace the Configurator's default admin, across all markets. Default-admin-only.
    function set_owner(address _new_default_admin) external;

    function set_view(address _controller, address _view_blueprint) external;

    function set_callback(address _controller, address _cb) external;

    function default_admin() external view returns (address);

    function admins(address _controller) external view returns (address);
}
