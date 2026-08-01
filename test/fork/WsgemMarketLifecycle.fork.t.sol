// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {IERC20}               from "forge-std/interfaces/IERC20.sol";
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

/// @dev LLAMMA's trading surface, declared here rather than in `src/interfaces` because only this
///      suite trades against the AMM. Base form of the Vyper
///      `exchange(i, j, in_amount, min_amount, _for = msg.sender)`.
interface IAMMExchange {
    function exchange(uint256 i, uint256 j, uint256 in_amount, uint256 min_amount)
        external
        returns (uint256[2] memory);
}

/// @dev The wrapper's redemption surface, declared here for the payout-identity test only: the
///      shims never call any of it.
interface IWsgemRedeem {
    function redeem(uint256 amt) external returns (uint256 id);

    function canPass(address usr) external view returns (bool);

    function burnable() external view returns (bool);

    function cooldown() external view returns (uint256);

    function totalPending() external view returns (uint256);
}

/// @dev The wrapper's spread-setting surface, pranked as its ward in the zero-quote test.
interface IActFile {
    function setBpsout(uint256 bpsout_) external;
}

/// @notice The whole life of a market against live mainnet state: lend, borrow, accrue, repay,
///         withdraw, liquidate, and survive a mid-life feed pause.
/// @dev The creation-time fork suite proves a market can be BUILT; this one proves the market
///      built actually WORKS -- and in doing so it exercises every write-path selector the
///      Solidity interfaces translate by hand (`create_loan`, `repay`, `borrow_more`,
///      `liquidate`, `save_rate`, `deposit`, `withdraw`, `exchange`, and the Configurator's
///      levers), none of which any other test reaches. A hand-translated selector that is wrong
///      fails here, on a fork, rather than in production or -- worse -- mid-incident.
contract WsgemMarketLifecycleForkTest is Test {
    WstGBPMarketScript internal cfg;

    address internal WSGEM;
    address internal GEM;
    address internal FACTORY;
    address internal CONFIGURATOR;

    WsgemLlamalendOracle internal oracle;
    WsgemRateCalculator  internal calc;

    IVault          internal vault;
    ILendController internal controller;
    IAMM            internal amm;
    address         internal mp;
    address         internal dao;

    address internal lender     = makeAddr("lender");
    address internal borrower   = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant CAP        = 1_000_000e18;
    uint256 internal constant LIQUIDITY  = 100_000e18;
    uint256 internal constant COLLATERAL = 1_000e18;
    uint256 internal constant N_BANDS    = 10;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));

        cfg          = new WstGBPMarketScript();
        WSGEM        = cfg.WSGEM();
        GEM          = cfg.GEM();
        FACTORY      = cfg.FACTORY();
        CONFIGURATOR = cfg.CONFIGURATOR();

        oracle = new WsgemLlamalendOracle(IWsgem(WSGEM), cfg.MAX_UPSIDE_SPEED());
        calc = new WsgemRateCalculator(
            IWsgem(WSGEM), cfg.RATE_INTERVALS(), cfg.MAX_PUBLICATION_GAP(), cfg.MIN_CHECKPOINT_SPACING()
        );

        address predicted_ = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        mp = _deployPolicy(predicted_);
        address[3] memory m_ = _create(mp);
        require(m_[1] == predicted_, "controller mispredicted");

        vault      = IVault(m_[0]);
        controller = ILendController(m_[1]);
        amm        = IAMM(m_[2]);

        // What the DAO vote will do.
        dao = ILendFactory(FACTORY).admin();
        vm.prank(dao);
        IConfigurator(CONFIGURATOR).set_borrow_cap(address(controller), CAP);

        deal(GEM, lender, LIQUIDITY);
        deal(WSGEM, borrower, COLLATERAL);
    }

    // --- The lifecycle --------------------------------------------------------------------------

    function test_theFullLifecycleLendBorrowAccrueRepayWithdraw() public {
        // Lend.
        vm.startPrank(lender);
        IERC20(GEM).approve(address(vault), type(uint256).max);
        uint256 shares_ = vault.deposit(LIQUIDITY, lender);
        vm.stopPrank();
        assertGt(shares_, 0);
        assertEq(vault.totalAssets(), LIQUIDITY);

        // Borrow, sized by the controller's own cap-aware quote.
        uint256 max_ = controller.max_borrowable(COLLATERAL, N_BANDS, borrower);
        assertGt(max_, 0, "a lifted cap and a funded vault must make borrowing possible");
        uint256 debt_ = max_ / 2;

        vm.startPrank(borrower);
        IERC20(WSGEM).approve(address(controller), type(uint256).max);
        controller.create_loan(COLLATERAL, debt_, N_BANDS, borrower, address(0), "");
        vm.stopPrank();

        assertEq(IERC20(GEM).balanceOf(borrower), debt_, "the borrowed gem must arrive");
        assertTrue(controller.loan_exists(borrower));
        assertApproxEqAbs(controller.debt(borrower), debt_, 1);
        assertGt(controller.health(borrower, true), 0, "a half-of-max loan starts healthy");

        // Accrue. The policy floors at ~1% APR even on a fresh calculator, so debt must grow.
        skip(30 days);
        uint256 grown_ = controller.debt(borrower);
        assertGt(grown_, debt_, "a floored borrow rate still accrues interest");

        // Repay in full, interest included.
        deal(GEM, borrower, grown_ + 1e18);
        vm.startPrank(borrower);
        IERC20(GEM).approve(address(controller), type(uint256).max);
        controller.repay(controller.debt(borrower));
        vm.stopPrank();

        assertFalse(controller.loan_exists(borrower), "full repayment must close the loan");
        assertEq(
            IERC20(WSGEM).balanceOf(borrower), COLLATERAL, "the collateral must come back whole"
        );

        // Withdraw. Every coin was repaid, so the lender exits with principal and interest --
        // minus a dust allowance: the vault refuses to be left holding less than MIN_ASSETS
        // (10000 wei) unless emptied exactly, and the virtual shares' accrued wei makes an exact
        // empty impossible for a sole depositor. `maxWithdraw` does NOT account for this rule.
        uint256 exit_ = vault.maxWithdraw(lender);
        assertGe(exit_, LIQUIDITY, "principal plus interest must be on the table");
        vm.prank(lender);
        vault.withdraw(exit_ - 10_000, lender, lender);
        assertGe(
            IERC20(GEM).balanceOf(lender) + 10_001, LIQUIDITY, "principal must survive the trip"
        );
    }

    // --- The write-path wiring the deploy depends on ----------------------------------------------

    /// @dev The AMM updates its oracle before doing anything else on an exchange, even a
    ///      zero-sized one. This is the only AMM entry point that drives `price_w`, so it is the
    ///      wiring an idle-but-traded market keeps the ratchet warm through.
    function test_theAmmDrivesPriceWThroughExchangeTraffic() public {
        skip(3 days);
        assertLt(oracle.cachedTimestamp(), block.timestamp, "checkpoint is cold before the trade");

        IAMMExchange(address(amm)).exchange(0, 1, 0, 0);

        assertEq(
            oracle.cachedTimestamp(),
            block.timestamp,
            "one AMM trade must persist the oracle checkpoint"
        );
    }

    /// @dev `save_rate` -> policy `rate_write` -> calculator `rate_w`: a NAV publication must be
    ///      observed through ordinary market traffic with nothing calling the calculator
    ///      directly. This is the wiring the whole "no keeper required" claim rests on.
    function test_controllerTrafficAloneObservesAPublication() public {
        _lendAndBorrow(borrower, COLLATERAL, 0);
        assertEq(calc.checkpointCount(), 1, "only the deploy seed before the publication");

        skip(7 days);
        _setNav((IWsgem(WSGEM).navprice() * 10_007) / 10_000);

        vm.prank(borrower);
        controller.repay(1e18);

        assertEq(calc.checkpointCount(), 2, "an ordinary repay must checkpoint the publication");
    }

    /// @dev The deploy's stated safety net, asserted rather than believed: `LendFactory.create`
    ///      calls `save_rate()` on the new controller, the policy's `rate_write()` is
    ///      controller-gated, so an MP bound to anything else must revert the whole creation.
    ///      Without this, a factory-nonce race between simulation and broadcast would ship a
    ///      market wired to a stranger's controller.
    function test_aMispredictedControllerMakesCreateRevert() public {
        address mp2_ = _deployPolicy(makeAddr("not-the-controller"));

        // Bind every argument to a local first: expectRevert arms the NEXT external call, and a
        // config getter inside the helper would otherwise be it.
        uint256 a_      = cfg.A();
        uint256 fee_    = cfg.FEE();
        uint256 loanD_  = cfg.LOAN_DISCOUNT();
        uint256 liqD_   = cfg.LIQUIDATION_DISCOUNT();
        uint256 limit_  = cfg.SUPPLY_LIMIT();

        vm.expectRevert("Controller only");
        ILendFactory(FACTORY).create(
            GEM, WSGEM, a_, fee_, loanD_, liqD_, address(oracle), mp2_, limit_
        );
    }

    // --- The documented sharpest edge --------------------------------------------------------------

    /// @dev A downward NAV publication passes through in one block, and hard liquidation follows.
    ///      This is the edge every doc in the repo names; here it is walked end to end.
    function test_aNavCollapseLiquidatesAtTheDocumentedEdge() public {
        uint256 max_ = _lendAndBorrow(borrower, COLLATERAL, 0);
        uint256 debt_ = (max_ * 95) / 100;

        vm.startPrank(borrower);
        controller.repay(controller.debt(borrower));
        controller.create_loan(COLLATERAL, debt_, N_BANDS, borrower, address(0), "");
        vm.stopPrank();
        assertGt(controller.health(borrower, true), 0);

        // The collapse: -10% in one publication, passed through undamped. The oracle reports the
        // redemption quote of the fallen NAV, read live through the wrapper.
        uint256 lower_ = (IWsgem(WSGEM).navprice() * 90) / 100;
        _setNav(lower_);
        assertEq(oracle.price(), IWsgem(WSGEM).burncost(), "a fall reaches the market in the same block");
        assertLt(oracle.price(), lower_, "and the quote sits below the fallen NAV");
        assertLt(controller.health(borrower, true), 0, "a 95%-of-max loan must be under water");

        // Hard liquidation clears it.
        uint256 need_ = controller.tokens_to_liquidate(borrower, 1e18);
        deal(GEM, liquidator, need_ + 1e18);
        vm.startPrank(liquidator);
        IERC20(GEM).approve(address(controller), type(uint256).max);
        controller.liquidate(borrower, 0, 1e18);
        vm.stopPrank();

        assertFalse(controller.loan_exists(borrower));
        assertGt(
            IERC20(WSGEM).balanceOf(liquidator), 0, "the liquidator must receive the collateral"
        );
    }

    /// @dev The freeze design's whole justification: a paused feed must leave repayment,
    ///      borrowing and trading alive on the held price rather than bricking the market.
    function test_aMidLifeFreezeKeepsTheMarketServiceable() public {
        _lendAndBorrow(borrower, COLLATERAL, 0);
        uint256 held_ = oracle.price();
        uint256 nav_  = IWsgem(WSGEM).navprice();

        // The feed pauses with a position open.
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(uint256(0)));
        assertTrue(oracle.frozen());
        assertEq(oracle.price(), held_, "held, never zero");

        // Trading, repaying and borrowing all continue against the held price.
        IAMMExchange(address(amm)).exchange(0, 1, 0, 0);
        assertEq(amm.price_oracle(), held_);

        vm.startPrank(borrower);
        controller.repay(1e18);
        controller.borrow_more(0, 1e18, borrower, address(0), "");
        vm.stopPrank();
        assertTrue(controller.loan_exists(borrower));

        // The feed returns lower: the fall passes through in one block, as designed.
        _setNav((nav_ * 95) / 100);
        assertEq(oracle.price(), IWsgem(WSGEM).burncost());
        assertLt(oracle.price(), held_);
    }

    // --- The Configurator levers an incident depends on --------------------------------------------

    /// @dev `set_price_oracle` is the emergency lever docs/07 reaches for on a feed-key
    ///      compromise. An emergency is the wrong moment to discover a selector typo, so the
    ///      whole swap is exercised here: deploy a replacement, repoint, verify the AMM follows.
    function test_theEmergencyOracleSwapLeverWorks() public {
        WsgemLlamalendOracle fresh_ = new WsgemLlamalendOracle(IWsgem(WSGEM), cfg.MAX_UPSIDE_SPEED());

        vm.prank(dao);
        IConfigurator(CONFIGURATOR).set_price_oracle(address(controller), address(fresh_), 0.01e18);

        assertEq(amm.price_oracle_contract(), address(fresh_), "the AMM must follow the swap");
        assertEq(amm.price_oracle(), fresh_.price());
    }

    /// @dev The lever the interface used to omit: the DAO can add a per-market administrator,
    ///      who is then authorized for the per-market setters alongside the DAO.
    function test_aCustomAdminCanBeDelegatedTheMarket() public {
        address custom_ = makeAddr("custom-admin");

        vm.prank(dao);
        IConfigurator(CONFIGURATOR).set_custom_admin(address(controller), custom_);
        assertEq(IConfigurator(CONFIGURATOR).admins(address(controller)), custom_);

        vm.prank(custom_);
        IConfigurator(CONFIGURATOR).set_borrow_cap(address(controller), CAP / 2);
        assertEq(controller.borrow_cap(), CAP / 2, "the delegate must hold the per-market setters");

        // The delegation is not transitive: appointing admins and replacing the owner are
        // default-admin-only, so the custom admin cannot extend or transfer its own authority.
        vm.prank(custom_);
        vm.expectRevert("Not admin");
        IConfigurator(CONFIGURATOR).set_custom_admin(address(controller), address(0xBAD));

        vm.prank(custom_);
        vm.expectRevert("Not admin");
        IConfigurator(CONFIGURATOR).set_owner(address(0xBAD));
    }

    // --- Selector sweep -----------------------------------------------------------------------------

    /// @dev Every hand-translated view selector that no other test touches, resolved against the
    ///      live deployments in one place. A selector that is wrong reverts or decodes garbage
    ///      here.
    function test_everyRemainingTranslatedSelectorResolvesAgainstLiveCode() public {
        // Factory.
        ILendFactory f_ = ILendFactory(FACTORY);
        assertGt(f_.market_count(), 0);
        uint256 id_ = f_.vaults_index(address(vault));
        address[2] memory coins_ = f_.coins(id_);
        assertEq(coins_[0], GEM, "factory coins are [borrowed, collateral]");
        assertEq(coins_[1], WSGEM);
        assertEq(f_.fee_receiver(address(controller)), f_.default_fee_receiver());
        assertGt(f_.amm_blueprint().code.length, 0);
        assertGt(f_.controller_blueprint().code.length, 0);
        assertGt(f_.vault_blueprint().code.length, 0);
        assertGt(f_.controller_view_blueprint().code.length, 0);

        // Vault.
        assertEq(vault.maxSupply(), cfg.SUPPLY_LIMIT(), "the ninth create argument, verified");
        assertGt(vault.pricePerShare(true), 0);
        assertGt(vault.pricePerShare(false), 0);
        assertEq(vault.borrowed_token(), GEM);
        assertEq(vault.collateral_token(), WSGEM);
        assertEq(vault.factory(), FACTORY);
        assertEq(vault.amm(), address(amm));
        assertEq(vault.decimals(), 18);
        assertEq(vault.maxDeposit(lender), cfg.SUPPLY_LIMIT());
        vault.lend_apr();
        vault.borrow_apr();

        // Controller.
        assertEq(controller.factory(), FACTORY);
        assertEq(controller.total_debt(), 0);
        assertEq(controller.borrowed_token(), GEM);
        assertEq(controller.collateral_token(), WSGEM);
        controller.admin_percentage();
        controller.save_rate();
        assertEq(controller.tokens_to_liquidate(borrower, 1e18), 0, "no loan, nothing to repay");
        controller.create_loan_health_preview(COLLATERAL, 1e18, N_BANDS, borrower, true);

        // AMM.
        assertEq(amm.coins(0), GEM, "AMM coin 0 is the borrowed token");
        assertEq(amm.coins(1), WSGEM);
        amm.active_band();
        assertGt(amm.get_p(), 0);

        // Monetary policy, the read side the Controller uses. Unlike target_rate, rate() is NOT
        // clamped to the floor: at zero utilization it sits at low_ratio times the base -- which
        // makes this the one place LOW_RATIO's effect is observable on a fresh market.
        assertApproxEqAbs(
            IHyperbolicDynamicMP(mp).rate(),
            (IHyperbolicDynamicMP(mp).target_rate() * cfg.LOW_RATIO()) / 1e18,
            2,
            "at zero utilization the curve sits at low_ratio x base"
        );
    }

    /// @dev The claim the floor-price design rests on, executed rather than quoted: redeeming N
    ///      wsgem pays exactly N * burncost / 1e18 in gem, through the real path -- compliance
    ///      gate, burn window, zero cooldown -- at the pinned block. This is what licenses
    ///      "price() is the executable floor".
    function test_redemptionPaysExactlyTheReportedPrice() public {
        IWsgemRedeem w_ = IWsgemRedeem(WSGEM);
        assertTrue(w_.canPass(borrower), "the compliance gate admits an arbitrary address");
        assertTrue(w_.burnable(), "the burn window is open at the pinned block");
        assertEq(w_.cooldown(), 0, "zero cooldown: redemption settles in the transaction");

        uint256 amt_   = 100e18;
        uint256 quote_ = IWsgem(WSGEM).burncost();
        assertEq(oracle.price(), quote_);

        uint256 before_ = IERC20(GEM).balanceOf(borrower);
        vm.prank(borrower);
        w_.redeem(amt_);

        assertEq(
            IERC20(GEM).balanceOf(borrower) - before_,
            (amt_ * quote_) / 1e18,
            "redemption pays exactly price() per wsgem"
        );
    }

    /// @dev The wrapper's spread is settable to 100% -- the live act accepts `bpsout == 10_000`
    ///      -- which zeroes `burncost()` while the feed stays live. That must read as a one-wei
    ///      floor, not as a pause holding the old price, and restoring the spread must recover
    ///      the last real anchor. Exercised against the live act, pranked as its ward.
    function test_aHundredPercentSpreadFloorsThePriceAndRecovers() public {
        address act_    = IWsgem(WSGEM).act();
        address ward_   = 0xa73c94969dE90Edb159D29922C42fF24beDFA085;
        uint256 anchor_ = oracle.price_w();

        vm.prank(ward_);
        IActFile(act_).setBpsout(10_000);

        assertEq(IWsgem(WSGEM).burncost(), 0, "the live wrapper quotes zero at a 100% spread");
        assertEq(oracle.price(), 1, "a live zero floors the price at one wei");
        assertEq(oracle.price_w(), 1);
        assertFalse(oracle.frozen(), "this is not a pause");
        assertTrue(oracle.quoteIsZero());

        vm.prank(ward_);
        IActFile(act_).setBpsout(25);

        assertEq(oracle.price(), anchor_, "restoration recovers the anchor exactly");
        assertFalse(oracle.quoteIsZero());
    }

    /// @dev The "against the full supply" claim, asserted rather than sampled: at the pinned
    ///      block the wrapper's gem reserves cover every outstanding wsgem redeeming at the
    ///      current quote, plus claims already pending settlement. The redemption test above
    ///      proves the price; this proves the depth.
    function test_reservesCoverAFullSupplyExitAtTheQuote() public view {
        uint256 owed_ = (IERC20(WSGEM).totalSupply() * IWsgem(WSGEM).burncost()) / 1e18
            + IWsgemRedeem(WSGEM).totalPending();
        assertGe(
            IERC20(GEM).balanceOf(WSGEM),
            owed_,
            "reserves must cover a full-supply exit at the quote plus pending claims"
        );
    }

    /// @dev Feeds `PIP_READ_GAS`: each of the two reads the oracle makes -- the pip's NAV for
    ///      the pause signal and the wrapper's `burncost()` for the price -- must cost no more
    ///      than a tenth of the cap, so a legitimate proxy upgrade has an order of magnitude of
    ///      headroom before it starts reading as a pause.
    function test_theLiveReadsCostFarBelowTheGasCap() public view {
        address pip_ = IWsgem(WSGEM).pip();

        // Warm the accounts the way a live call path would have them.
        IPip(pip_).read();
        IWsgem(WSGEM).burncost();

        uint256 g0_ = gasleft();
        IPip(pip_).read();
        uint256 navRead_ = g0_ - gasleft();

        g0_ = gasleft();
        IWsgem(WSGEM).burncost();
        uint256 quoteRead_ = g0_ - gasleft();

        assertLt(navRead_ * 10, oracle.PIP_READ_GAS(), "cap must be >= 10x the NAV read");
        assertLt(quoteRead_ * 10, oracle.PIP_READ_GAS(), "cap must be >= 10x the quote read");
    }

    // --- Helpers ------------------------------------------------------------------------------------

    /// @notice Deposit vault liquidity and open a loan for `who_`; returns the max borrowable the
    ///         loan was sized against. `debt_ == 0` borrows half of max.
    function _lendAndBorrow(address who_, uint256 collateral_, uint256 debt_)
        internal
        returns (uint256 max_)
    {
        vm.startPrank(lender);
        IERC20(GEM).approve(address(vault), type(uint256).max);
        vault.deposit(LIQUIDITY, lender);
        vm.stopPrank();

        max_ = controller.max_borrowable(collateral_, N_BANDS, who_);
        if (debt_ == 0) debt_ = max_ / 2;

        vm.startPrank(who_);
        IERC20(WSGEM).approve(address(controller), type(uint256).max);
        IERC20(GEM).approve(address(controller), type(uint256).max);
        controller.create_loan(collateral_, debt_, N_BANDS, who_, address(0), "");
        vm.stopPrank();
    }

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

    /// @dev Same override the creation-time fork suite uses: everything downstream reads through
    ///      the pip's one method, so the whole live stack still runs; only the number is ours.
    function _setNav(uint256 nav_) internal {
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(nav_));
        require(IWsgem(WSGEM).navprice() == nav_, "nav override did not take");
    }
}
