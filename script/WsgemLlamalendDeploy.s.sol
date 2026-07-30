// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console}   from "forge-std/Script.sol";

import {WsgemLlamalendOracle} from "../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../src/WsgemRateCalculator.sol";
import {IWsgem}               from "../src/interfaces/IWsgem.sol";
import {ILendFactory}         from "../src/interfaces/ILendFactory.sol";
import {ILendController}      from "../src/interfaces/ILendController.sol";
import {IVault}               from "../src/interfaces/IVault.sol";
import {IAMM}                 from "../src/interfaces/IAMM.sol";
import {IHyperbolicDynamicMP} from "../src/interfaces/IMonetaryPolicy.sol";

/// @title WsgemLlamalendConfig
/// @notice Every per-deployment value, as overridable getters.
/// @dev Solidity cannot override a `public constant`, so each of these is a `pure virtual` getter
///      instead. A concrete deployment overrides them all in one file and touches nothing else --
///      see script/WstGBP.s.sol. Nothing here names a token.
abstract contract WsgemLlamalendConfig {
    // --- Curve Llamalend V2, Ethereum mainnet ----------------------------------------------
    //
    // Identical for every wsgem. Recorded in docs/reference/addresses.md.

    function FACTORY() public pure virtual returns (address) {
        return 0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd;
    }

    function CONFIGURATOR() public pure virtual returns (address) {
        return 0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC;
    }

    // --- The market --------------------------------------------------------------------------

    /// @notice The wsgem, used as collateral.
    function WSGEM() public pure virtual returns (address);

    /// @notice The gem, borrowed. Cross-checked against `wsgem.gem()` before anything is deployed.
    function GEM() public pure virtual returns (address);

    // --- Oracle shim -------------------------------------------------------------------------

    /// @notice Maximum relative increase in the reported price per second, WAD-scaled.
    function MAX_UPSIDE_SPEED() public pure virtual returns (uint256);

    // --- Rate calculator ---------------------------------------------------------------------

    /// @notice How many publication intervals the yield measurement spans. In [2, 7].
    function RATE_INTERVALS() public pure virtual returns (uint256);

    /// @notice Grace past the last publication before the reported rate starts decaying, seconds.
    function MAX_PUBLICATION_GAP() public pure virtual returns (uint256);

    // --- AMM / Controller risk parameters ------------------------------------------------------
    //
    // Bounds, all enforced on-chain at creation:
    //   2 <= A <= 10000                                    (LendFactory)
    //   1e6 <= fee <= min(1e18 * 4 / A, 1e17)              (AMM constructor)
    //   0 < liquidation_discount < loan_discount < 1e18    (LendFactory)

    function A() public pure virtual returns (uint256);
    function FEE() public pure virtual returns (uint256);
    function LOAN_DISCOUNT() public pure virtual returns (uint256);
    function LIQUIDATION_DISCOUNT() public pure virtual returns (uint256);

    /// @notice Vault deposit cap. `type(uint256).max` is unlimited; the borrow cap is separate and
    ///         starts at zero regardless.
    function SUPPLY_LIMIT() public pure virtual returns (uint256);

    // --- Monetary policy curve -----------------------------------------------------------------
    //
    // Bounds enforced by HyperbolicDynamicMP:
    //   1e16 <= target_utilization <= 99e16
    //   low_ratio >= 1e16, high_ratio <= 100e18, rate_shift <= 100e18

    function TARGET_UTILIZATION() public pure virtual returns (uint256);
    function LOW_RATIO() public pure virtual returns (uint256);
    function HIGH_RATIO() public pure virtual returns (uint256);
    function RATE_SHIFT() public pure virtual returns (uint256);
}

/// @title WsgemLlamalendScript
/// @notice Checks shared by the oracle and market deploys.
/// @dev The oracle assertions live here rather than on the oracle script because the market deploy
///      needs them just as much: it can be handed an already-deployed oracle through
///      `WSGEM_ORACLE`, and an oracle that is perfectly valid for a *different* wsgem would satisfy
///      `LendFactory.create`'s only checks -- a non-zero price, and `price_w()` agreeing with
///      `price()` -- while pricing the market's collateral in terms of an unrelated asset. The
///      factory cannot catch that; nothing on-chain can. It has to be caught here.
abstract contract WsgemLlamalendScript is Script, WsgemLlamalendConfig {
    /// @notice Checks that run before anything is broadcast, against live chain state.
    function _preflight() internal view virtual {
        IWsgem wsgem_ = IWsgem(WSGEM());
        require(wsgem_.gem() == GEM(), "gem mismatch");
        require(wsgem_.decimals() == 18, "wsgem is not 18 decimals");
        require(wsgem_.navprice() > 0, "feed is paused -- refusing to deploy against a zero NAV");
    }

    /// @notice Every property an oracle must have to be used by this market, fresh or reused.
    /// @dev Deliberately not just a wiring check. `price_w() == price()` is the factory's own
    ///      requirement, restated here so a broken oracle fails before the market is built on it
    ///      rather than half way through `create`.
    function _assertOracle(WsgemLlamalendOracle oracle_) internal {
        require(address(oracle_) != address(0), "oracle: zero address");
        require(address(oracle_).code.length > 0, "oracle: no code at address");

        // The wiring. Any of these mismatching means the oracle prices something other than this
        // market's collateral, however healthy it looks.
        require(address(oracle_.WSGEM()) == WSGEM(), "oracle: wsgem mismatch");
        require(oracle_.GEM() == GEM(), "oracle: gem mismatch");
        require(address(oracle_.PIP()) == IWsgem(WSGEM()).pip(), "oracle: pip mismatch");
        require(oracle_.MAX_UPSIDE_SPEED() == MAX_UPSIDE_SPEED(), "oracle: speed mismatch");

        // Liveness. A frozen oracle is reporting a held price, which is not a basis for setting a
        // market's opening band.
        require(!oracle_.frozen(), "oracle: feed is frozen -- refusing to build on a held price");

        uint256 p_ = oracle_.price();
        require(p_ > 0, "oracle: zero price");
        require(oracle_.price_w() == p_, "oracle: price_w != price");
        require(p_ <= oracle_.spotPrice(), "oracle: reported above spot");
    }

    /// @notice The extra check that only holds for an oracle deployed in this run.
    /// @dev A fresh oracle checkpoints the feed in its constructor, so the rate limit cannot be
    ///      binding against itself yet and the reported price must equal the live NAV exactly. A
    ///      reused oracle may legitimately sit below spot while it absorbs a publication, so this
    ///      is not asserted there.
    function _assertFreshOracle(WsgemLlamalendOracle oracle_) internal view {
        require(oracle_.price() == IWsgem(WSGEM()).navprice(), "oracle: price != navprice");
    }
}

/// @title WsgemOracleScript
/// @notice Deploys the ownerless price oracle shim on its own.
/// @dev Deliberately separable from the market. The documented order is to deploy the oracle
///      first and watch its reported price against the live feed across at least one publication
///      before a market depends on it -- see docs/05-deploy-mainnet.md.
abstract contract WsgemOracleScript is WsgemLlamalendScript {
    function run() external returns (WsgemLlamalendOracle oracle_) {
        _preflight();

        vm.startBroadcast();
        oracle_ = new WsgemLlamalendOracle(IWsgem(WSGEM()), MAX_UPSIDE_SPEED());
        vm.stopBroadcast();

        _assertOracle(oracle_);
        _assertFreshOracle(oracle_);
        _reportOracle(oracle_);
    }

    function _reportOracle(WsgemLlamalendOracle oracle_) internal view {
        console.log("---");
        console.log("oracle ............:", address(oracle_));
        console.log("  wsgem ...........:", address(oracle_.WSGEM()));
        console.log("  gem .............:", oracle_.GEM());
        console.log("  pip .............:", address(oracle_.PIP()));
        console.log("  max upside/sec ..:", oracle_.MAX_UPSIDE_SPEED());
        console.log("  price ...........:", oracle_.price());
        console.log("---");
        console.log("NEXT: record this address, then watch price() against the live NAV across at");
        console.log("      least one publication before deploying the market against it.");
    }
}

/// @title WsgemMarketScript
/// @notice Deploys the rate calculator and monetary policy, then creates the Llamalend V2 market.
/// @dev Market creation is permissionless, but the market it produces is inert: `borrow_cap` is
///      zero and only a Curve DAO vote can lift it. See docs/06-post-deployment.md.
abstract contract WsgemMarketScript is WsgemLlamalendScript {
    /// @dev Path is relative to the project root and covered by `fs_permissions` in foundry.toml.
    string internal constant MP_INITCODE_PATH = "script/bytecode/HyperbolicDynamicMP.initcode.hex";

    struct Deployment {
        WsgemLlamalendOracle oracle;
        WsgemRateCalculator  rateCalculator;
        address              monetaryPolicy;
        address              vault;
        address              controller;
        address              amm;
    }

    function run() external returns (Deployment memory d_) {
        _preflight();

        // Reuse an oracle deployed and observed earlier where one is given; otherwise deploy a
        // fresh one in this run.
        address existing_ = vm.envOr("WSGEM_ORACLE", address(0));

        // Validate a supplied oracle BEFORE broadcasting anything. `LendFactory.create` only
        // checks that the price is non-zero and that `price_w()` agrees with `price()` -- both of
        // which a perfectly healthy oracle for some *other* asset would satisfy, producing a market
        // whose collateral is priced in terms of something it has no relationship to. This is the
        // only place that can be caught, and it is cheaper to catch it before the first transaction
        // than after five.
        if (existing_ != address(0)) _assertOracle(WsgemLlamalendOracle(existing_));

        vm.startBroadcast();

        d_.oracle = existing_ == address(0)
            ? new WsgemLlamalendOracle(IWsgem(WSGEM()), MAX_UPSIDE_SPEED())
            : WsgemLlamalendOracle(existing_);

        d_.rateCalculator =
            new WsgemRateCalculator(IWsgem(WSGEM()), RATE_INTERVALS(), MAX_PUBLICATION_GAP());

        // HyperbolicDynamicMP binds its Controller as an immutable, but the Controller only exists
        // once LendFactory.create runs -- and create needs the monetary policy address. The way
        // out is to predict the Controller: create deploys vault, then amm, then controller as
        // three consecutive CREATEs from the factory, so the controller lands at nonce + 2. The
        // constructor only stores the address, so a prediction is safe; a wrong one makes create
        // revert rather than silently misconfigure the market.
        address predicted_ = vm.computeCreateAddress(FACTORY(), vm.getNonce(FACTORY()) + 2);
        d_.monetaryPolicy  = _deployMonetaryPolicy(predicted_, address(d_.rateCalculator));

        address[3] memory market_ = ILendFactory(FACTORY()).create(
            GEM(), // borrowed
            WSGEM(), // collateral
            A(),
            FEE(),
            LOAN_DISCOUNT(),
            LIQUIDATION_DISCOUNT(),
            address(d_.oracle),
            d_.monetaryPolicy,
            SUPPLY_LIMIT()
        );

        vm.stopBroadcast();

        (d_.vault, d_.controller, d_.amm) = (market_[0], market_[1], market_[2]);
        require(d_.controller == predicted_, "controller address mispredicted");

        _assertOracle(d_.oracle);
        if (existing_ == address(0)) _assertFreshOracle(d_.oracle);
        _assertMarket(d_);
        _reportMarket(d_);
    }

    /// @notice Deploy Curve's monetary policy from the vendored initcode.
    /// @dev See script/bytecode/PROVENANCE.md for what this bytecode is and how it is verified.
    function _deployMonetaryPolicy(address controller_, address rateCalculator_)
        internal
        returns (address mp_)
    {
        bytes memory code_ = abi.encodePacked(
            vm.parseBytes(vm.readFile(MP_INITCODE_PATH)),
            abi.encode(
                controller_,
                rateCalculator_,
                TARGET_UTILIZATION(),
                LOW_RATIO(),
                HIGH_RATIO(),
                RATE_SHIFT()
            )
        );

        assembly ("memory-safe") {
            mp_ := create(0, add(code_, 0x20), mload(code_))
        }
        require(mp_ != address(0), "monetary policy deploy failed");
    }

    /// @dev Extends the shared token checks with the market parameters the chain will enforce.
    function _preflight() internal view override {
        super._preflight();

        ILendFactory factory_ = ILendFactory(FACTORY());
        require(!factory_.paused(), "factory is paused");

        // The AMM enforces this and reverts with no useful message. Catch it before broadcasting.
        uint256 maxFee_ = (1e18 * 4) / A();
        if (maxFee_ > 1e17) maxFee_ = 1e17;
        require(FEE() >= 1e6 && FEE() <= maxFee_, "fee out of AMM bounds for this A");
        require(A() >= 2 && A() <= 10000, "A out of bounds");
        require(LIQUIDATION_DISCOUNT() > 0, "liquidation discount = 0");
        require(LOAN_DISCOUNT() > LIQUIDATION_DISCOUNT(), "loan discount <= liquidation discount");
        require(LOAN_DISCOUNT() < 1e18, "loan discount >= 100%");
    }

    function _assertMarket(Deployment memory d_) internal view {
        ILendFactory factory_ = ILendFactory(FACTORY());

        // The market round-trips through the factory's own registry.
        uint256 id_ = factory_.vaults_index(d_.vault);
        ILendFactory.Market memory m_ = factory_.markets(id_);
        require(m_.vault == d_.vault, "registry: vault mismatch");
        require(m_.controller == d_.controller, "registry: controller mismatch");
        require(m_.amm == d_.amm, "registry: amm mismatch");
        require(m_.collateral_token == WSGEM(), "registry: collateral mismatch");
        require(m_.borrowed_token == GEM(), "registry: borrowed mismatch");
        require(m_.price_oracle == address(d_.oracle), "registry: oracle mismatch");
        require(m_.monetary_policy == d_.monetaryPolicy, "registry: monetary policy mismatch");

        // The wiring the factory does not report.
        require(IVault(d_.vault).asset() == GEM(), "vault: asset mismatch");
        require(IVault(d_.vault).controller() == d_.controller, "vault: controller mismatch");
        require(IAMM(d_.amm).price_oracle_contract() == address(d_.oracle), "amm: oracle mismatch");
        require(IAMM(d_.amm).admin() == d_.controller, "amm: admin is not the controller");
        require(IAMM(d_.amm).A() == A(), "amm: A mismatch");
        require(IAMM(d_.amm).fee() == FEE(), "amm: fee mismatch");

        ILendController c_ = ILendController(d_.controller);
        require(c_.amm() == d_.amm, "controller: amm mismatch");
        require(c_.vault() == d_.vault, "controller: vault mismatch");
        require(c_.monetary_policy() == d_.monetaryPolicy, "controller: monetary policy mismatch");
        require(c_.collateral_token() == WSGEM(), "controller: collateral mismatch");
        require(c_.borrowed_token() == GEM(), "controller: borrowed mismatch");
        require(c_.loan_discount() == LOAN_DISCOUNT(), "controller: loan discount mismatch");
        require(
            c_.liquidation_discount() == LIQUIDATION_DISCOUNT(),
            "controller: liquidation discount mismatch"
        );
        require(c_.configurator() == CONFIGURATOR(), "controller: configurator mismatch");

        // The monetary policy is bound to this market and nothing else.
        IHyperbolicDynamicMP mp_ = IHyperbolicDynamicMP(d_.monetaryPolicy);
        require(mp_.CONTROLLER() == d_.controller, "mp: controller mismatch");
        require(mp_.RATE_CALCULATOR() == address(d_.rateCalculator), "mp: rate calculator mismatch");

        // Borrowing is shut. Stated as an assert so a market that somehow ships open is caught
        // here rather than discovered later.
        require(c_.borrow_cap() == 0, "controller: borrow cap is not zero on a fresh market");
    }

    function _reportMarket(Deployment memory d_) internal view {
        IHyperbolicDynamicMP mp_ = IHyperbolicDynamicMP(d_.monetaryPolicy);

        console.log("---");
        console.log("oracle ............:", address(d_.oracle));
        console.log("rate calculator ...:", address(d_.rateCalculator));
        console.log("monetary policy ...:", d_.monetaryPolicy);
        console.log("vault .............:", d_.vault);
        console.log("controller ........:", d_.controller);
        console.log("amm ...............:", d_.amm);
        console.log("---");
        console.log("collateral ........:", WSGEM());
        console.log("borrowed ..........:", GEM());
        console.log("price .............:", d_.oracle.price());
        console.log("measured yield/sec :", d_.rateCalculator.rate());
        console.log("mp target rate/sec :", mp_.target_rate());
        console.log("mp target apr .....:", mp_.target_apr());
        console.log("---");
        console.log("WARNING: borrow_cap is 0. This market cannot be borrowed from until a Curve");
        console.log("         DAO vote calls Configurator.set_borrow_cap on the controller.");
        console.log("         Configurator:", CONFIGURATOR());
        console.log("NEXT: docs/06-post-deployment.md");
    }
}
