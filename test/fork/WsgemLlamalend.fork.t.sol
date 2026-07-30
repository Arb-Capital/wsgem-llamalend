// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../../src/WsgemRateCalculator.sol";
import {IWsgem}               from "../../src/interfaces/IWsgem.sol";
import {IPip}                 from "../../src/interfaces/IPip.sol";
import {ILendFactory}         from "../../src/interfaces/ILendFactory.sol";
import {ILendController}      from "../../src/interfaces/ILendController.sol";
import {IConfigurator}        from "../../src/interfaces/IConfigurator.sol";
import {IVault}               from "../../src/interfaces/IVault.sol";
import {IAMM}                 from "../../src/interfaces/IAMM.sol";
import {IHyperbolicDynamicMP} from "../../src/interfaces/IMonetaryPolicy.sol";
import {WstGBPMarketScript}   from "../../script/WstGBP.s.sol";
import {MockPip, MockGem, MockWsgem} from "../mocks/MockWsgem.sol";

/// @notice Exposes the deploy script's internal oracle validation so it can be tested directly.
/// @dev The check runs before any broadcast, so there is no way to reach it through `run()` without
///      a real deploy. Inheriting the production script keeps the test honest: this is the same
///      code path a broadcast takes, not a reimplementation of it.
contract MarketScriptHarness is WstGBPMarketScript {
    function assertOracle(WsgemLlamalendOracle oracle_) external {
        _assertOracle(oracle_);
    }
}

/// @notice End-to-end against live mainnet state: the real wsgem, the real feed, and the real
///         Curve `LendFactory`.
/// @dev This is the gate the unit suite cannot be. It proves the three things a deploy actually
///      depends on and that mocks cannot show: the oracle reads the live feed correctly, the
///      controller-address prediction holds against the real factory, and `create` succeeds with
///      the parameters the concrete script carries.
///
///      Run with `make test-fork`, which hard-fails without a mainnet RPC rather than skipping.
contract WsgemLlamalendForkTest is Test {
    WstGBPMarketScript internal cfg;

    address internal WSGEM;
    address internal GEM;
    address internal FACTORY;
    address internal CONFIGURATOR;

    WsgemLlamalendOracle internal oracle;
    WsgemRateCalculator  internal calc;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));

        // Read the production constants from the production script rather than restating them, so
        // this suite cannot drift away from what is actually deployed.
        cfg          = new WstGBPMarketScript();
        WSGEM        = cfg.WSGEM();
        GEM          = cfg.GEM();
        FACTORY      = cfg.FACTORY();
        CONFIGURATOR = cfg.CONFIGURATOR();

        oracle = new WsgemLlamalendOracle(IWsgem(WSGEM), cfg.MAX_UPSIDE_SPEED());
        calc   = new WsgemRateCalculator(IWsgem(WSGEM), cfg.RATE_INTERVALS(), cfg.MAX_PUBLICATION_GAP());
    }

    // --- The live wsgem ---------------------------------------------------------------------------

    function test_theConfiguredPairIsWhatTheChainSays() public view {
        assertEq(IWsgem(WSGEM).gem(), GEM, "the wsgem's own gem must be the borrowed token");
        assertEq(IWsgem(WSGEM).decimals(), 18);
        assertGt(IWsgem(WSGEM).navprice(), 0, "the feed must be live at the pinned block");
    }

    function test_theOracleReportsTheLiveNav() public view {
        uint256 nav_ = IWsgem(WSGEM).navprice();
        assertEq(oracle.price(), nav_, "a fresh oracle reports the live NAV exactly");
        assertEq(oracle.spotPrice(), nav_);
    }

    function test_theOracleReadsThePipDirectlyAndIdenticallyToTheWrapper() public view {
        // The shim caches `pip` at construction instead of hopping through the wrapper. That is
        // only sound if the two agree, which is what this pins.
        assertEq(address(oracle.PIP()), IWsgem(WSGEM).pip());
        assertEq(IPip(address(oracle.PIP())).read(), IWsgem(WSGEM).navprice());
    }

    function test_theFactoryPriceCheckPassesAgainstTheLiveFeed() public {
        uint256 p_ = oracle.price();
        assertGt(p_, 0, "LendFactory rejects a zero price");
        assertEq(oracle.price_w(), p_, "LendFactory asserts price_w() == price()");
    }

    // --- Curve's live infrastructure ---------------------------------------------------------------

    function test_theFactoryIsLiveAndOpen() public view {
        ILendFactory f_ = ILendFactory(FACTORY);
        assertEq(f_.version(), "2.0.0");
        assertFalse(f_.paused(), "market creation is permissionless but not while paused");
        assertGt(FACTORY.code.length, 0);
        assertGt(CONFIGURATOR.code.length, 0);
    }

    // --- The whole deploy --------------------------------------------------------------------------

    /// @dev The load-bearing trick: `HyperbolicDynamicMP` binds its Controller immutably, but the
    ///      Controller is created by `LendFactory.create`, which itself needs the policy address.
    ///      `create` deploys vault, amm, controller as three consecutive CREATEs, so the controller
    ///      lands at `CREATE(factory, nonce + 2)`. If that ever stops being true, this fails here
    ///      rather than on mainnet.
    function test_theControllerAddressPredictionHolds() public {
        address predicted_ = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        address[3] memory m_ = _create(_deployPolicy(predicted_));
        assertEq(m_[1], predicted_, "controller mispredicted");
    }

    function test_theMarketIsCreatedAndRegistered() public {
        address predicted_   = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        address mp_          = _deployPolicy(predicted_);
        address[3] memory m_ = _create(mp_);

        (address vault_, address controller_, address amm_) = (m_[0], m_[1], m_[2]);

        ILendFactory f_ = ILendFactory(FACTORY);
        ILendFactory.Market memory rec_ = f_.markets(f_.vaults_index(vault_));

        assertEq(rec_.vault, vault_);
        assertEq(rec_.controller, controller_);
        assertEq(rec_.amm, amm_);
        assertEq(rec_.collateral_token, WSGEM, "collateral must be the wsgem");
        assertEq(rec_.borrowed_token, GEM, "borrowed must be the gem");
        assertEq(rec_.price_oracle, address(oracle));
        assertEq(rec_.monetary_policy, mp_);

        assertEq(IVault(vault_).asset(), GEM);
        assertEq(IAMM(amm_).price_oracle_contract(), address(oracle));
        assertEq(IAMM(amm_).admin(), controller_);
        assertEq(IAMM(amm_).A(), cfg.A());
        assertEq(IAMM(amm_).fee(), cfg.FEE());

        ILendController c_ = ILendController(controller_);
        assertEq(c_.monetary_policy(), mp_);
        assertEq(c_.loan_discount(), cfg.LOAN_DISCOUNT());
        assertEq(c_.liquidation_discount(), cfg.LIQUIDATION_DISCOUNT());
        assertEq(c_.configurator(), CONFIGURATOR);
    }

    /// @dev The AMM is initialised from the oracle's price, so a market created against a shim that
    ///      under-reports would start mid-band in the wrong place.
    function test_theAmmStartsAtTheOraclePrice() public {
        address predicted_   = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        address[3] memory m_ = _create(_deployPolicy(predicted_));

        assertEq(IAMM(m_[2]).price_oracle(), oracle.price(), "AMM must start at the reported price");
    }

    /// @notice A fresh market cannot be borrowed from, and only the Configurator can change that.
    /// @dev The single most important post-deployment fact, asserted rather than only documented.
    function test_borrowingIsShutUntilTheConfiguratorOpensIt() public {
        address predicted_   = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        address[3] memory m_ = _create(_deployPolicy(predicted_));
        ILendController c_   = ILendController(m_[1]);

        assertEq(c_.borrow_cap(), 0, "a fresh market must ship with a zero borrow cap");

        // The factory admin is the Curve DAO on mainnet, so this is what the vote does.
        address admin_ = ILendFactory(FACTORY).admin();
        vm.prank(admin_);
        IConfigurator(CONFIGURATOR).set_borrow_cap(m_[1], 1_000_000e18);

        assertEq(c_.borrow_cap(), 1_000_000e18, "only the Configurator can open the market");
    }

    /// @dev The policy is wired to this market's controller and to our calculator, and nothing else.
    function test_theMonetaryPolicyIsBoundToThisMarket() public {
        address predicted_   = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        address mp_          = _deployPolicy(predicted_);
        address[3] memory m_ = _create(mp_);

        assertEq(IHyperbolicDynamicMP(mp_).CONTROLLER(), m_[1]);
        assertEq(IHyperbolicDynamicMP(mp_).RATE_CALCULATOR(), address(calc));

        // A brand-new calculator has no measurable span, so it reports zero and the policy floors.
        assertEq(calc.rate(), 0);
        assertEq(IHyperbolicDynamicMP(mp_).target_rate(), 317_097_920, "MIN_TARGET_RATE");
    }

    /// @dev Once the calculator has a window's worth of live NAV history behind it, the policy must
    ///      follow it rather than sitting on the floor. Simulated by warping the fork forward and
    ///      writing the wsgem's own NAV slot, since the pinned block cannot contain the future.
    function test_thePolicyFollowsTheCalculatorOnceTheWindowHasSubstance() public {
        address predicted_   = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        address mp_          = _deployPolicy(predicted_);
        _create(mp_);

        uint256 nav_ = IWsgem(WSGEM).navprice();

        // Eight weeks of the observed cadence: ~6.8 bp per week, about 3.54% APR.
        for (uint256 w_; w_ < 8; ++w_) {
            skip(7 days);
            nav_ = nav_ + (nav_ * 354) / 10_000 / 52;
            _setNav(nav_);
            calc.rate_w();
        }

        assertGt(calc.rate(), 317_097_920, "the calculator must have risen off the floor");
        assertApproxEqRel(calc.apr(), 0.0354e18, 0.05e18, "~3.54% APR in, ~3.54% APR out");
        assertEq(IHyperbolicDynamicMP(mp_).target_rate(), calc.rate(), "policy must follow it");
    }

    // --- A reused oracle must be validated ---------------------------------------------------------
    //
    // `WSGEM_ORACLE` lets the market deploy reuse an oracle deployed and observed earlier. The
    // factory's own checks -- non-zero price, `price_w()` agreeing with `price()` -- are satisfied
    // by any healthy oracle, including one built for a completely different asset. Nothing on-chain
    // catches that, so the deploy script has to.

    function test_aCorrectlyWiredOracleIsAccepted() public {
        MarketScriptHarness h_ = new MarketScriptHarness();
        h_.assertOracle(oracle);
    }

    function test_anOracleForADifferentAssetIsRejected() public {
        // Healthy, live, non-zero, `price_w() == price()` -- and pricing the wrong token.
        MockPip   pip_   = new MockPip(2e18);
        MockGem   gem_   = new MockGem(18);
        MockWsgem other_ = new MockWsgem(address(gem_), address(pip_), 18);
        WsgemLlamalendOracle wrong_ =
            new WsgemLlamalendOracle(IWsgem(address(other_)), cfg.MAX_UPSIDE_SPEED());

        // It would sail through the factory.
        assertGt(wrong_.price(), 0);
        assertEq(wrong_.price_w(), wrong_.price());

        MarketScriptHarness h_ = new MarketScriptHarness();
        vm.expectRevert(bytes("oracle: wsgem mismatch"));
        h_.assertOracle(wrong_);
    }

    function test_anOracleWithTheWrongSpeedIsRejected() public {
        WsgemLlamalendOracle wrong_ =
            new WsgemLlamalendOracle(IWsgem(WSGEM), cfg.MAX_UPSIDE_SPEED() + 1);

        MarketScriptHarness h_ = new MarketScriptHarness();
        vm.expectRevert(bytes("oracle: speed mismatch"));
        h_.assertOracle(wrong_);
    }

    function test_anAddressWithNoCodeIsRejected() public {
        MarketScriptHarness h_ = new MarketScriptHarness();
        vm.expectRevert(bytes("oracle: no code at address"));
        h_.assertOracle(WsgemLlamalendOracle(address(0xdead)));
    }

    function test_aFrozenOracleIsRejected() public {
        // Deploy against the live feed, then pause it. The oracle keeps reporting its last good
        // price -- correct behaviour for a live market, but not a basis for opening a new one.
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(uint256(0)));
        assertTrue(oracle.frozen());
        assertGt(oracle.price(), 0);

        MarketScriptHarness h_ = new MarketScriptHarness();
        vm.expectRevert(bytes("oracle: feed is frozen -- refusing to build on a held price"));
        h_.assertOracle(oracle);
    }

    // --- Helpers ------------------------------------------------------------------------------------

    function _deployPolicy(address controller_) internal returns (address mp_) {
        bytes memory code_ = abi.encodePacked(
            vm.parseBytes(vm.readFile("script/bytecode/HyperbolicDynamicMP.initcode.hex")),
            abi.encode(
                controller_,
                address(calc),
                cfg.TARGET_UTILIZATION(),
                cfg.LOW_RATIO(),
                cfg.HIGH_RATIO(),
                cfg.RATE_SHIFT()
            )
        );
        assembly ("memory-safe") {
            mp_ := create(0, add(code_, 0x20), mload(code_))
        }
        require(mp_ != address(0), "monetary policy deploy failed");
    }

    function _create(address mp_) internal returns (address[3] memory) {
        return ILendFactory(FACTORY).create(
            GEM,
            WSGEM,
            cfg.A(),
            cfg.FEE(),
            cfg.LOAN_DISCOUNT(),
            cfg.LIQUIDATION_DISCOUNT(),
            address(oracle),
            mp_,
            cfg.SUPPLY_LIMIT()
        );
    }

    /// @dev Overrides what the live feed reports, without touching its storage layout. Everything
    ///      downstream -- the wsgem's own `navprice()`, both shims, the AMM -- reads through this
    ///      one method, so the whole live stack still runs; only the published number is ours.
    function _setNav(uint256 nav_) internal {
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(nav_));
        require(IWsgem(WSGEM).navprice() == nav_, "nav override did not take");
    }
}
