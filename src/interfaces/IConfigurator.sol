// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IConfigurator
/// @notice Llamalend V2 `Configurator` -- the permissioned administration surface for a market.
/// @dev Every function here is gated on the market's administrator: either the Configurator's
///      default admin (the Curve DAO on mainnet) or a per-controller custom admin. None of it is
///      callable by a market deployer.
///
///      This is the complete set of levers a deployed market is exposed to, and it belongs in the
///      trust model of anything integrating one -- in particular `set_price_oracle`, which can
///      repoint the market away from the shim in this repo, and `set_monetary_policy`.
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

    function default_admin() external view returns (address);

    function admins(address _controller) external view returns (address);
}
