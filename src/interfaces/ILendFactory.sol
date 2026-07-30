// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title ILendFactory
/// @notice Llamalend V2 `LendFactory`. Solidity translation of
///         `curve_stablecoin/interfaces/ILendFactory.vyi`.
/// @dev Market creation is PERMISSIONLESS -- `create` guards only on the factory's pause flag.
///      What it does not give you is a usable market: every market ships with `borrow_cap == 0`,
///      and lifting it takes a Curve DAO vote calling `Configurator.set_borrow_cap`. See
///      docs/06-post-deployment.md.
interface ILendFactory {
    /// @dev Field order matters -- it mirrors the Vyper struct, and getting it wrong silently
    ///      shifts every address by one slot when decoding.
    struct Market {
        address vault;
        address controller;
        address amm;
        address collateral_token;
        address borrowed_token;
        address price_oracle;
        address monetary_policy;
    }

    /// @notice Deploy a vault/controller/AMM triplet and register it.
    /// @dev The three contracts are deployed as three consecutive CREATEs in the order
    ///      vault, amm, controller. The controller therefore lands at
    ///      `CREATE(factory, nonce + 2)`, which is what makes a controller-bound monetary policy
    ///      deployable BEFORE the market exists.
    ///
    ///      Validation performed here (LendFactory.vy):
    ///        - borrowed != collateral
    ///        - MIN_A (2) <= A <= MAX_A (10000)
    ///        - liquidation_discount > 0
    ///        - loan_discount < 1e18
    ///        - loan_discount > liquidation_discount
    ///        - price_oracle.price() > 0 and price_oracle.price_w() == price()
    ///      The AMM constructor additionally enforces
    ///      `1e6 <= fee <= min(1e18 * MIN_TICKS / A, 1e17)` with MIN_TICKS = 4.
    /// @return Addresses in the order [vault, controller, amm]. Note this differs from the
    ///         deployment order above.
    function create(
        address _borrowed_token,
        address _collateral_token,
        uint256 _A,
        uint256 _fee,
        uint256 _loan_discount,
        uint256 _liquidation_discount,
        address _price_oracle,
        address _monetary_policy,
        uint256 _supply_limit
    ) external returns (address[3] memory);

    function markets(uint256 _n) external view returns (Market memory);

    function market_count() external view returns (uint256);

    function vaults_index(address _vault) external view returns (uint256);

    function coins(uint256 _vault_id) external view returns (address[2] memory);

    function admin() external view returns (address);

    /// @notice Where a market's admin share of interest is sent.
    /// @dev Base form of the Vyper `fee_receiver(_controller = msg.sender)`; resolves to the
    ///      custom receiver if one is set, else `default_fee_receiver()`.
    function fee_receiver(address _controller) external view returns (address);

    function default_fee_receiver() external view returns (address);

    function paused() external view returns (bool);

    function version() external view returns (string memory);

    function amm_blueprint() external view returns (address);

    function controller_blueprint() external view returns (address);

    function vault_blueprint() external view returns (address);

    function controller_view_blueprint() external view returns (address);
}
