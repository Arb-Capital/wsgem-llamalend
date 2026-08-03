// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {console2}             from "forge-std/console2.sol";
import {IERC20}               from "forge-std/interfaces/IERC20.sol";
import {DownsideDampedOracle} from "../mocks/DownsideDampedOracle.sol";
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

    // --- Modelling a publication that steps: what it costs, and what damping it would cost --------
    //
    // A donation attack against a Llamalend market inflates the collateral's redemption rate and
    // takes the book through hard liquidation. The precedent is LlamaLend sDOLA-long2
    // (2 March 2026): an oracle reading a spot ERC-4626 `convertToAssets()` was moved ~13.8%
    // atomically and 27 borrowers were hard-liquidated for ~822k crvUSD of seized equity. It is
    // worst where the market holds most of the collateral's supply -- there, one trade both
    // soft-liquidates the book and captures the float whose redemption shrinks the denominator
    // the donation then moves. Post-mortem: gov.curve.finance, "LlamaLend sDOLA-long2".
    //
    // A wsgem has no share/asset ratio to donate into -- `IWsgem` is deliberately not ERC-4626 --
    // so that attack has no entry point here. What it does have is the SHAPE the attack exploits:
    // a redemption quote that can step. Curve's post-sDOLA position is that a Llamalend oracle
    // should never permit an instantaneous jump for any reason, which is direction-blind; this
    // shim conforms upward and diverges downward on purpose. These tests price both halves of
    // that rather than arguing either -- the attack itself against the cap and against no cap
    // (below), and two step sizes DOWN against this shim and against a symmetrically damped one
    // (here), which is the divergence.
    //
    // WHAT THIS MODEL IS AND IS NOT. Arbitrage is crude: halving chunks toward the redemption bid
    // rather than solving for the optimal trade, one taker with fixed funding, no competition and
    // no gas. It is enough that soft liquidation actually happens -- without traders a fork market
    // never converts and every arm overstates the loss -- and enough to show that the greedy
    // strategy takes nothing. It is NOT a proof that no strategy extracts value. The comparison
    // between arms is the output; the absolute figures are indicative.

    /// @dev The sDOLA-shaped move: ~13.8% of the NAV in one publication.
    uint256 internal constant STEP_BP = 1380;

    /// @dev A move sized to the liquidation band instead: big enough to put the most levered
    ///      position under water, small enough that its collateral still covers its debt. This is
    ///      the only window in which anyone extracts anything, and it is narrow -- measured on this
    ///      book, 4% does not reach it and 9% is already past it into insolvency, where there is no
    ///      equity left to seize and nobody bids at all. 13.8%, the sDOLA-sized move, overshoots it
    ///      entirely.
    uint256 internal constant SMALL_STEP_BP = 700;

    /// @dev Daily ticks -- 0.25% a tick against a ~35 bp band at A = 285, so soft liquidation gets
    ///      band-scale granularity -- capped well past the ~55 days a 13.8% fall takes.
    uint256 internal constant TICK      = 1 days;
    uint256 internal constant MAX_TICKS = 120;

    uint256 internal constant ARB_FUNDING   = 50_000e18;
    uint256 internal constant ARB_CHUNK     = 64e18;
    uint256 internal constant ARB_MIN_CHUNK = 0.01e18;
    uint256 internal constant ARB_STEPS     = 64;

    address internal arb = makeAddr("arbitrageur");
    address[3] internal book;

    /// @dev Kept in storage rather than on the stack: the report carries thirteen figures and the
    ///      two tests that fill it are already at the stack limit.
    struct Ledger {
        uint256 fair0;
        uint256 fair1;
        uint256 book0;
        uint256 book1;
        uint256 vault0;
        uint256 vault1;
        int256  arb0;
        int256  arb1;
        uint256 liq0;
        uint256 liq1;
        uint256 open;
        uint256 coll0;
        uint256 coll1;
        uint256 ammSpot;
        uint256 ammOracle;
        uint256 liquidated;
        uint256 repricedInDays;
    }

    Ledger internal led;

    /// @dev Pass-through, sDOLA-sized. The fall reaches the market in one block, which is also to
    ///      say it arrives faster than soft liquidation can work.
    function test_aStepDownIsPassedThroughAndSkipsSoftLiquidation() public {
        _runDownStep(STEP_BP, false);
        console2.log("--- -13.8%, pass-through (shipped) -------------------------");
        _report();

        assertEq(oracle.price(), led.fair1, "the fall reaches the market in the same block");
        // Past the liquidation band the collateral no longer covers the debt, so no rational
        // liquidator bids and the shortfall simply sits there. That is the honest bad outcome of
        // a step this size, and it is the SAME outcome damped -- see the comparison below.
        assertEq(led.liquidated, 0, "nobody liquidates a position that cannot repay");
        assertGt(led.open, 0, "so the shortfall stays open");
    }

    /// @dev The counterfactual: the same fall, the same positions, the same arbitrage, metered out
    ///      at the same 0.25%/day the upside already carries.
    function test_theSameStepDampedGivesSoftLiquidationTimeToWork() public {
        _runDownStep(STEP_BP, true);
        console2.log("--- -13.8%, damped at 0.25%/day (counterfactual) -----------");
        _report();
        assertLt(led.repricedInDays, (MAX_TICKS * TICK) / 1 days, "the descent must complete");
    }

    /// @dev Pass-through at liquidation-band size. This is the sDOLA extraction shape: positions
    ///      under water but still solvent, so a liquidator bids and the borrower pays the discount.
    function test_aSmallStepDownIsWhereABorrowerActuallyPays() public {
        _runDownStep(SMALL_STEP_BP, false);
        console2.log("--- -7%, pass-through (shipped) ----------------------------");
        _report();

        assertGt(led.liquidated, 0, "this step size must reach the liquidation band");
        assertGt(led.book0, led.book1, "and the borrower must pay for being in it");
        assertEq(led.open, 0, "solvent, so nothing is left unbacked");
        // The discount is a transfer, not a burn: what the borrower loses the liquidator takes.
        assertApproxEqRel(
            led.liq1 - led.liq0, led.book0 - led.book1, 0.25e18, "loss must land on the liquidator"
        );
    }

    /// @dev The same, damped. Whether metering the fall keeps a borrower out of the liquidation
    ///      band, or just delays it there, is the question the asymmetry turns on.
    function test_theSameSmallStepDamped() public {
        _runDownStep(SMALL_STEP_BP, true);
        console2.log("--- -7%, damped at 0.25%/day (counterfactual) --------------");
        _report();

        assertGt(led.liquidated, 0, "damping delays the liquidation, it does not avoid it");
        assertGt(led.repricedInDays, 7, "and it costs weeks of unrecognised loss to do so");
    }

    /// @dev The comparison the docs rest on, asserted rather than printed. Both arms run in one
    ///      test against one market state, so the difference cannot be an artefact of two setUps.
    /// @dev `led` is storage and resets with the revert; the two figures carried across it are
    ///      locals, which live in this call frame and are untouched by a state revert.
    function test_dampingTheDownsideDoesNotProtectTheBorrower() public {
        uint256 snap_ = vm.snapshotState();

        _runDownStep(SMALL_STEP_BP, false);
        uint256 passLoss_ = led.book0 - led.book1;
        uint256 passLiq_  = led.liquidated;

        vm.revertToState(snap_);

        _runDownStep(SMALL_STEP_BP, true);
        uint256 dampLoss_ = led.book0 - led.book1;

        console2.log("--- -7%: pass-through vs damped, one market state ----------");
        console2.log("  borrower loses, pass-through (gem) :", passLoss_ / 1e18);
        console2.log("  borrower loses, damped       (gem) :", dampLoss_ / 1e18);
        console2.log("  days the damped arm took           :", led.repricedInDays);

        assertGt(passLiq_, 0, "the control must reach the liquidation band, or this proves nothing");
        assertGe(
            dampLoss_, passLoss_, "damping the downside must not be sold as protecting the borrower"
        );
        assertGt(led.repricedInDays, 7, "and what it does buy is weeks of unrecognised loss");
    }

    /// @dev One scenario, two oracles. Same book, same publication, same takers; the only
    ///      difference is whether the fall arrives in a block or over weeks.
    function _runDownStep(uint256 stepBp_, bool damped_) internal {
        DownsideDampedOracle shim_;
        if (damped_) {
            shim_ = new DownsideDampedOracle(IWsgem(WSGEM), cfg.MAX_UPSIDE_SPEED());
            vm.prank(dao);
            IConfigurator(CONFIGURATOR).set_price_oracle(
                address(controller), address(shim_), 0.01e18
            );
            assertEq(amm.price_oracle_contract(), address(shim_), "the market must follow the swap");
        }

        led.fair0 = _openBook();
        _fundTakers();

        _setNav((IWsgem(WSGEM).navprice() * (10_000 - stepBp_)) / 10_000);
        led.fair1 = IWsgem(WSGEM).burncost();
        _mark(true);

        if (!damped_) {
            _arbToward(led.fair1);
            led.liquidated = _liquidateUnderwater();
        } else {
            assertGt(shim_.price(), led.fair1, "a damped oracle holds above the fallen quote");

            uint256 ticks_;
            while (shim_.price() > led.fair1 && ticks_ < MAX_TICKS) {
                vm.warp(block.timestamp + TICK);
                shim_.price_w();
                _arbToward(led.fair1);
                led.liquidated += _liquidateUnderwater();
                ++ticks_;
            }
            led.repricedInDays = (ticks_ * TICK) / 1 days;
        }

        _mark(false);
    }

    // --- The sDOLA attack, replayed in shape -------------------------------------------------------
    //
    // The post-mortem's mechanism, which is not the one intuition suggests. Inflating the oracle
    // UP is what liquidated 27 borrowers, and it only works after a separate step:
    //
    //   1. One permissionless `exchange()` dumps borrowed-token into the AMM and buys the
    //      collateral out of every occupied band, leaving the bands holding gem. That is
    //      soft-liquidation, done deliberately and at a loss. On its own it liquidates nobody --
    //      health IMPROVES, because the bands now hold the borrowed asset.
    //   2. The redemption rate is inflated. On its own this liquidates nobody either: a higher
    //      collateral price is a healthier position.
    //
    // Together they are lethal, because `get_x_down` values a soft-liquidated band by asking what
    // its gem would buy back at the current oracle -- and that round trip carries `p_o` CUBED in
    // the DENOMINATOR (AMM.vy: `p_o**2 / p_o_down * p_o / p_o_up`). A 1.3% rate rise cost the
    // sDOLA book ~4 points of health. Positions sitting on 0.3-0.8% margin went straight under.
    //
    // Two arms below, and the attacker is handed the rate move FOR FREE in both -- no donation,
    // no supply capture, no cost for the half of the attack a wsgem has no path to at all. What
    // is measured is whether the remainder pays once its expensive half is removed.

    /// @dev ~13.79%: the sDOLA rate move, 1.189 -> 1.353.
    uint256 internal constant INFLATE_BP = 1379;

    /// @dev Enough gem to buy the whole book's collateral out of its bands.
    uint256 internal constant DUMP = 10_000e18;

    /// @dev The shipped cap admits 0.25%/day, so step 2 lands as nothing and the attacker is left
    ///      holding the cost of step 1.
    function test_theSdolaAttackShapeIsUnprofitableUnderTheCap() public {
        _runInflationAttack(true);
        console2.log("--- sDOLA attack shape, capped at 0.25%/day (shipped) ------");
        _report();

        assertEq(led.liquidated, 0, "the cap must leave nothing to liquidate");
        assertLt(led.arb1, led.arb0, "and the attacker must be out of pocket for trying");
    }

    /// @dev The same sequence with no cap: the sDOLA oracle's behaviour, on this book.
    /// @dev These two assertions are what make the capped arm mean anything. A model in which the
    ///      attack fails everywhere proves only that the model is broken, so the control has to
    ///      reproduce the attack before the treatment is allowed to refute it.
    function test_theSameAttackShapeUncappedIsWhatTheCapIsWorth() public {
        _runInflationAttack(false);
        console2.log("--- sDOLA attack shape, uncapped (control) -----------------");
        _report();

        assertGt(led.liquidated, 0, "uncapped, the attack must take a position");
        assertGt(led.arb1, led.arb0, "uncapped, the attack must pay -- net of step 1's cost");
    }

    /// @dev One sequence, two oracles. `capped_ == false` swaps in an oracle with no limit in
    ///      either direction, which is the sDOLA market's behaviour for this purpose.
    function _runInflationAttack(bool capped_) internal {
        if (!capped_) {
            DownsideDampedOracle open_ = new DownsideDampedOracle(IWsgem(WSGEM), 0);
            vm.prank(dao);
            IConfigurator(CONFIGURATOR).set_price_oracle(
                address(controller), address(open_), 0.01e18
            );
        }

        led.fair0 = _openBook();
        deal(GEM, arb, ARB_FUNDING);
        vm.startPrank(arb);
        IERC20(GEM).approve(address(amm), type(uint256).max);
        IERC20(GEM).approve(address(controller), type(uint256).max);
        IERC20(WSGEM).approve(address(amm), type(uint256).max);
        vm.stopPrank();

        led.fair1 = led.fair0;
        _mark(true);

        // Step 1: buy the book's collateral out of its bands. Deliberately unprofitable.
        vm.prank(arb);
        IAMMExchange(address(amm)).exchange(0, 1, DUMP, 0);
        led.coll1 = _bookCollateral(); // reused as the post-dump reading; _mark(false) overwrites

        // Step 2: the rate moves up. Free, in this model.
        _setNav((IWsgem(WSGEM).navprice() * (10_000 + INFLATE_BP)) / 10_000);
        led.fair1 = IWsgem(WSGEM).burncost();
        led.ammOracle = amm.price_oracle();

        // Step 3: take the book.
        led.liquidated = _liquidateUnderwaterBy(arb);
        _mark(false);
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

    // --- Helpers for the downside model -------------------------------------------------------------

    /// @notice Deposit liquidity once and open three loans at 60/80/95% of max. Returns the
    ///         redemption quote they were opened against.
    function _openBook() internal returns (uint256 fair_) {
        book = [borrower, makeAddr("borrower-b"), makeAddr("borrower-c")];
        uint256[3] memory pct_ = [uint256(60), 80, 95];

        vm.startPrank(lender);
        IERC20(GEM).approve(address(vault), type(uint256).max);
        vault.deposit(LIQUIDITY, lender);
        vm.stopPrank();

        for (uint256 i_; i_ < book.length; ++i_) {
            address who_ = book[i_];
            deal(WSGEM, who_, COLLATERAL);

            uint256 max_ = controller.max_borrowable(COLLATERAL, N_BANDS, who_);
            vm.startPrank(who_);
            IERC20(WSGEM).approve(address(controller), type(uint256).max);
            IERC20(GEM).approve(address(controller), type(uint256).max);
            controller.create_loan(COLLATERAL, (max_ * pct_[i_]) / 100, N_BANDS, who_, address(0), "");
            vm.stopPrank();
        }
        fair_ = IWsgem(WSGEM).burncost();
    }

    /// @dev Fund and approve both takers up front. Their P&L is only readable if their balances
    ///      are set once rather than topped up per trade.
    function _fundTakers() internal {
        deal(GEM, arb, ARB_FUNDING);
        deal(WSGEM, arb, ARB_FUNDING);
        vm.startPrank(arb);
        IERC20(GEM).approve(address(amm), type(uint256).max);
        IERC20(WSGEM).approve(address(amm), type(uint256).max);
        vm.stopPrank();

        deal(GEM, liquidator, ARB_FUNDING);
        vm.prank(liquidator);
        IERC20(GEM).approve(address(controller), type(uint256).max);
    }

    /// @notice Walk the AMM toward the redemption bid, keeping only the trades that actually pay.
    /// @dev Crude on purpose -- see the note above the tests. `coins(0)` is the borrowed gem and
    ///      `coins(1)` the collateral, so `exchange(0, 1, ...)` buys collateral and
    ///      `exchange(1, 0, ...)` sells it.
    ///
    ///      Two properties matter, and the model is wrong without either.
    ///
    ///      Every chunk is executed against a snapshot and rolled back unless it raised the
    ///      arbitrageur's net worth marked at the redemption bid. Without that test the loop is
    ///      not an arbitrageur at all: LLAMMA's dynamic fee scales with how far the oracle has
    ///      just moved -- the `1 - r**3` term, which a 13.8% step drives into the tens of percent
    ///      -- so a loop that trades merely because the price is out of line hands the fee to the
    ///      borrowers whose bands it is trading against and reports its own loss as extraction.
    ///
    ///      And the size halves rather than giving up. A fixed chunk large enough to matter after
    ///      a 13.8% step is far too large for the 25 bp a damped oracle moves in a day: it
    ///      overshoots, prices as unprofitable, and the model then reports that no arbitrage
    ///      exists in the arm where arbitrage is the entire mechanism being measured.
    function _arbToward(uint256 fair_) internal {
        uint256 chunk_ = ARB_CHUNK;

        for (uint256 k_; k_ < ARB_STEPS; ++k_) {
            uint256 p_ = amm.get_p();
            if (p_ == 0) return;
            if (p_ <= (fair_ * 10_010) / 10_000 && p_ >= (fair_ * 9_990) / 10_000) return;

            uint256 i_     = p_ > fair_ ? 1 : 0;
            int256  worth_ = _netWorth(arb, fair_);
            uint256 snap_  = vm.snapshotState();
            bool    kept_;

            vm.prank(arb);
            try IAMMExchange(address(amm)).exchange(i_, 1 - i_, chunk_, 0) returns (
                uint256[2] memory got_
            ) {
                kept_ = got_[1] > 0 && _netWorth(arb, fair_) > worth_;
            } catch {
                kept_ = false;
            }

            if (kept_) continue;

            vm.revertToState(snap_);
            chunk_ /= 2;
            if (chunk_ < ARB_MIN_CHUNK) return;
        }
    }

    /// @notice Everything `who_` owns, valued in gem at `p_`, net of debt: wallet balances plus
    ///         whatever the AMM is holding on their behalf.
    function _netWorth(address who_, uint256 p_) internal view returns (int256) {
        uint256[4] memory s_ = controller.user_state(who_);
        uint256 assets_ = IERC20(GEM).balanceOf(who_) + (IERC20(WSGEM).balanceOf(who_) * p_) / 1e18
            + (s_[0] * p_) / 1e18 + s_[1];
        return int256(assets_) - int256(controller.debt(who_));
    }

    /// @notice The book's equity, each position floored at zero.
    /// @dev The floor is what makes this a measure of what BORROWERS lose. Below zero the loss has
    ///      stopped being theirs -- a debt larger than the collateral behind it is cleared at the
    ///      lender's expense, and clearing it registers as a borrower "gain" if the sum is taken
    ///      raw. That leg is counted where it lands, in `vault.totalAssets()`.
    function _bookEquity(uint256 p_) internal view returns (uint256 total_) {
        for (uint256 i_; i_ < book.length; ++i_) {
            int256 w_ = _netWorth(book[i_], p_);
            if (w_ > 0) total_ += uint256(w_);
        }
    }

    /// @notice Debt still open and no longer covered by the position behind it.
    /// @dev Only counts positions that are still open. Once a shortfall is liquidated through it
    ///      is realised against the vault, and `vault.totalAssets()` is where it shows up.
    function _openShortfall(uint256 p_) internal view returns (uint256 bad_) {
        for (uint256 i_; i_ < book.length; ++i_) {
            uint256[4] memory s_ = controller.user_state(book[i_]);
            uint256 backing_     = (s_[0] * p_) / 1e18 + s_[1];
            uint256 debt_        = controller.debt(book[i_]);
            if (debt_ > backing_) bad_ += debt_ - backing_;
        }
    }

    /// @notice Hard-liquidate every under-water position a liquidator would actually take.
    /// @dev The profitability test matters as much here as it does in `_arbToward`, and for a
    ///      sharper reason. Funding a liquidator on demand and letting it pay whatever
    ///      `tokens_to_liquidate` asks makes it buy collateral above the redemption bid -- it
    ///      absorbs the shortfall itself, and the model then reports a market where nobody lost
    ///      anything. A position nobody will liquidate is the actual outcome: it stays open, and
    ///      it shows up in `_openShortfall`.
    function _liquidateUnderwater() internal returns (uint256 n_) {
        return _liquidateUnderwaterBy(liquidator);
    }

    function _liquidateUnderwaterBy(address taker_) internal returns (uint256 n_) {
        uint256 fair_ = IWsgem(WSGEM).burncost();

        for (uint256 i_; i_ < book.length; ++i_) {
            address who_ = book[i_];
            if (!controller.loan_exists(who_)) continue;
            if (controller.health(who_, true) >= 0) continue;
            if (controller.tokens_to_liquidate(who_, 1e18) > IERC20(GEM).balanceOf(taker_)) {
                continue;
            }

            uint256 worth_ = _plainWorth(taker_, fair_);
            uint256 snap_  = vm.snapshotState();

            vm.prank(taker_);
            try controller.liquidate(who_, 0, 1e18) {
                if (_plainWorth(taker_, fair_) <= worth_) {
                    vm.revertToState(snap_);
                    continue;
                }
                ++n_;
            } catch {
                vm.revertToState(snap_);
            }
        }
    }

    /// @dev How much collateral the book still holds in the AMM. Soft liquidation converts it to
    ///      gem, so a figure that does not move means the model produced no soft liquidation.
    function _bookCollateral() internal view returns (uint256 total_) {
        for (uint256 i_; i_ < book.length; ++i_) total_ += controller.user_state(book[i_])[0];
    }

    /// @dev Wallet-only worth, for the two actors that never hold a position.
    function _plainWorth(address who_, uint256 p_) internal view returns (uint256) {
        return IERC20(GEM).balanceOf(who_) + (IERC20(WSGEM).balanceOf(who_) * p_) / 1e18;
    }

    /// @dev Whole gem units. The comparison between the two arms is the output, not the precision.
    ///      Everything is marked at the same post-step quote in both arms, so the mark-to-market
    ///      move itself cancels and what is left is what the episode cost.
    function _mark(bool before_) internal {
        if (before_) {
            led.book0  = _bookEquity(led.fair1);
            led.vault0 = vault.totalAssets();
            led.arb0   = _netWorth(arb, led.fair1);
            led.liq0   = _plainWorth(liquidator, led.fair1);
            led.coll0  = _bookCollateral();
            led.ammSpot   = amm.get_p();
            led.ammOracle = amm.price_oracle();
        } else {
            led.book1  = _bookEquity(led.fair1);
            led.vault1 = vault.totalAssets();
            led.arb1   = _netWorth(arb, led.fair1);
            led.liq1   = _plainWorth(liquidator, led.fair1);
            led.open   = _openShortfall(led.fair1);
            led.coll1  = _bookCollateral();
        }
    }

    function _report() internal view {
        console2.log("  quote before / after  (wad) :", led.fair0, led.fair1);
        console2.log("  borrower equity lost  (gem) :", (int256(led.book0) - int256(led.book1)) / 1e18);
        console2.log("  lender assets lost    (gem) :", (int256(led.vault0) - int256(led.vault1)) / 1e18);
        console2.log("  taker net             (gem) :", (led.arb1 - led.arb0) / 1e18);
        console2.log("  liquidator gain       (gem) :", (int256(led.liq1) - int256(led.liq0)) / 1e18);
        console2.log("  amm spot at the mark  (wad) :", led.ammSpot);
        console2.log("  oracle the amm sees   (wad) :", led.ammOracle);
        console2.log("  collateral in bands   (wsg) :", led.coll0 / 1e18, led.coll1 / 1e18);
        console2.log("  shortfall still open  (gem) :", led.open / 1e18);
        console2.log("  positions liquidated        :", led.liquidated);
        console2.log("  days to fully reprice       :", led.repricedInDays);
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
