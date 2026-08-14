// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}   from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {WsgemFxLlamalendOracle} from "../../src/WsgemFxLlamalendOracle.sol";
import {WsgemRateCalculator}    from "../../src/WsgemRateCalculator.sol";
import {IWsgem}                 from "../../src/interfaces/IWsgem.sol";
import {IPip}                   from "../../src/interfaces/IPip.sol";
import {IChainlinkAggregator}   from "../../src/interfaces/IChainlinkAggregator.sol";
import {ILendFactory}           from "../../src/interfaces/ILendFactory.sol";
import {ILendController}        from "../../src/interfaces/ILendController.sol";
import {IConfigurator}          from "../../src/interfaces/IConfigurator.sol";
import {IVault}                 from "../../src/interfaces/IVault.sol";
import {IAMM}                   from "../../src/interfaces/IAMM.sol";

import {WstGBPCrvUSDMarketScript} from "../../script/WstGBPCrvUSD.s.sol";

/// @dev LLAMMA's trading surface, declared locally for the same reason the tGBP lifecycle suite
///      declares it: only the lifecycle suites trade against the AMM.
interface IAMMExchange {
    function exchange(uint256 i, uint256 j, uint256 in_amount, uint256 min_amount)
        external
        returns (uint256[2] memory);
}

/// @dev The wrapper's redemption surface, declared locally for the liquidation-exit test only:
///      the shims never call any of it. Same shape the tGBP lifecycle suite declares.
interface IWsgemRedeem {
    function redeem(uint256 amt) external returns (uint256 id);

    function canPass(address usr) external view returns (bool);

    function burnable() external view returns (bool);

    function cooldown() external view returns (uint256);
}

/// @notice The life of the wstGBP/crvUSD market against live mainnet state: lend, borrow, accrue,
///         repay, withdraw, and survive both of this instance's freeze causes mid-life.
/// @dev The crvUSD sibling of `WsgemMarketLifecycle.fork.t.sol`. The creation-time suite
///      (`WstGBPCrvUSD.fork.t.sol`) proves this market can be BUILT; this one proves the market
///      built actually WORKS -- and specifically that every token that moves is crvUSD, not the
///      gem. The gem denominates the wrapper's redemption quote and NOTHING else here, which is
///      exactly the confusion an operator runbook once made and a suite that only lends tGBP can
///      never catch.
///
///      Deliberately smaller than the tGBP lifecycle suite: the economics modelling (step-down
///      arms, sDOLA replay, selector sweep) exercises machinery both markets share and lives
///      there once. What is instance-specific -- crvUSD in and out of every leg, and the FX
///      freeze cause the same-currency market does not have -- is what earns a place here.
///
///      Run with `make test-fork`, which hard-fails without a mainnet RPC rather than skipping.
contract WstGBPCrvUSDLifecycleForkTest is Test {
    WstGBPCrvUSDMarketScript internal cfg;

    address internal WSGEM;
    address internal GEM;
    address internal CRVUSD;
    address internal FACTORY;
    address internal CONFIGURATOR;

    WsgemFxLlamalendOracle internal oracle;
    WsgemRateCalculator    internal calc;

    IVault          internal vault;
    ILendController internal controller;
    IAMM            internal amm;
    address         internal mp;
    address         internal dao;

    address internal lender     = makeAddr("lender");
    address internal borrower   = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");
    address internal arb        = makeAddr("arbitrageur");

    uint256 internal constant CAP        = 1_000_000e18;
    uint256 internal constant LIQUIDITY  = 100_000e18;
    uint256 internal constant COLLATERAL = 1_000e18;
    uint256 internal constant N_BANDS    = 10;

    /// @dev The drift arb, same crude shape and sizes as the tGBP suite's (halving chunks, keep
    ///      a trade only if it raised net worth marked at the oracle price). One chunk size
    ///      serves both directions for the same reason it does there: the pair trades near
    ///      parity -- 1 wstGBP is ~1.35 crvUSD.
    uint256 internal constant ARB_FUNDING   = 50_000e18;
    uint256 internal constant ARB_CHUNK     = 64e18;
    uint256 internal constant ARB_MIN_CHUNK = 0.01e18;
    uint256 internal constant ARB_STEPS     = 64;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));

        cfg          = new WstGBPCrvUSDMarketScript();
        WSGEM        = cfg.WSGEM();
        GEM          = cfg.GEM();
        CRVUSD       = cfg.BORROWED();
        FACTORY      = cfg.FACTORY();
        CONFIGURATOR = cfg.CONFIGURATOR();

        oracle = new WsgemFxLlamalendOracle(
            IWsgem(WSGEM),
            CRVUSD,
            IChainlinkAggregator(cfg.FX_FEED()),
            cfg.BORROWED_QUOTE(),
            cfg.BORROWED_QUOTE_KIND(),
            cfg.MAX_UPSIDE_SPEED(),
            cfg.MAX_FX_AGE()
        );
        calc = new WsgemRateCalculator(
            IWsgem(WSGEM), cfg.RATE_INTERVALS(), cfg.MAX_PUBLICATION_GAP(), cfg.MIN_CHECKPOINT_SPACING()
        );

        address predicted_ = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        mp = _deployPolicy(predicted_);
        address[3] memory m_ = ILendFactory(FACTORY).create(
            CRVUSD,
            WSGEM,
            cfg.A(),
            cfg.FEE(),
            cfg.LOAN_DISCOUNT(),
            cfg.LIQUIDATION_DISCOUNT(),
            address(oracle),
            mp,
            cfg.SUPPLY_LIMIT()
        );
        require(m_[1] == predicted_, "controller mispredicted");

        vault      = IVault(m_[0]);
        controller = ILendController(m_[1]);
        amm        = IAMM(m_[2]);

        // What the DAO vote will do -- this market's own vote, separate from the tGBP market's.
        dao = ILendFactory(FACTORY).admin();
        vm.prank(dao);
        IConfigurator(CONFIGURATOR).set_borrow_cap(address(controller), CAP);

        deal(CRVUSD, lender, LIQUIDITY);
        deal(WSGEM, borrower, COLLATERAL);
    }

    // --- The lifecycle --------------------------------------------------------------------------

    function test_theFullLifecycleLendBorrowAccrueRepayWithdraw() public {
        // Lend. The vault's asset is crvUSD -- the borrowed token -- not the gem the redemption
        // quote is denominated in. Seeding it is Step 4 of docs/06-post-deployment.md, and this is
        // the path that proves those instructions.
        vm.startPrank(lender);
        IERC20(CRVUSD).approve(address(vault), type(uint256).max);
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

        assertEq(IERC20(CRVUSD).balanceOf(borrower), debt_, "the borrowed crvUSD must arrive");
        assertEq(
            IERC20(GEM).balanceOf(borrower),
            0,
            "and no tGBP anywhere: the gem denominates the quote, it is not what this market lends"
        );
        assertTrue(controller.loan_exists(borrower));
        assertApproxEqAbs(controller.debt(borrower), debt_, 1);
        assertGt(controller.health(borrower, true), 0, "a half-of-max loan starts healthy");

        // Accrue. The policy floors at ~1% APR even on a fresh calculator, so debt must grow.
        // The month-long skip would also stale the GBP/USD round, and a frozen market accrues
        // too -- but that is the freeze tests' subject, not this one's, so the round is
        // re-stamped and the lifecycle stays the ordinary one.
        skip(30 days);
        _refreshFx();
        assertFalse(oracle.fxFrozen(), "the lifecycle under test is the live one");
        uint256 grown_ = controller.debt(borrower);
        assertGt(grown_, debt_, "a floored borrow rate still accrues interest");

        // Repay in full, interest included, in crvUSD.
        deal(CRVUSD, borrower, grown_ + 1e18);
        vm.startPrank(borrower);
        IERC20(CRVUSD).approve(address(controller), type(uint256).max);
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
            IERC20(CRVUSD).balanceOf(lender) + 10_001, LIQUIDITY, "principal must survive the trip"
        );
    }

    // --- The two freeze causes, mid-life --------------------------------------------------------

    /// @dev The freeze cause both instances share: the wsgem's feed pauses. Repayment, borrowing
    ///      and trading must all continue against the held price rather than bricking the market.
    function test_aMidLifeNavPauseKeepsTheMarketServiceable() public {
        _lendAndBorrow();
        uint256 held_ = oracle.price();

        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(uint256(0)));
        assertTrue(oracle.frozen());
        assertFalse(oracle.fxFrozen(), "and the freeze names the wsgem's feed, not the conversion");
        assertEq(oracle.price(), held_, "held, never zero");

        IAMMExchange(address(amm)).exchange(0, 1, 0, 0);
        assertEq(amm.price_oracle(), held_);

        vm.startPrank(borrower);
        controller.repay(1e18);
        controller.borrow_more(0, 1e18, borrower, address(0), "");
        vm.stopPrank();
        assertTrue(controller.loan_exists(borrower));
    }

    /// @dev The freeze cause only this instance has: the conversion legs go stale while the wsgem
    ///      stays perfectly healthy. Same required outcome -- the market keeps a price to repay,
    ///      borrow and trade against -- reached through the state the tGBP market cannot enter.
    function test_aMidLifeFxOutageKeepsTheMarketServiceable() public {
        _lendAndBorrow();
        uint256 held_ = oracle.price();

        skip(cfg.MAX_FX_AGE() + 1);
        assertTrue(oracle.fxFrozen(), "the conversion, not the wsgem, is what went dark");
        assertEq(oracle.price(), held_, "held, never zero");
        assertGt(oracle.quotePrice(), 0, "while the wsgem's own leg still reports");

        IAMMExchange(address(amm)).exchange(0, 1, 0, 0);
        assertEq(amm.price_oracle(), held_);

        vm.startPrank(borrower);
        controller.repay(1e18);
        controller.borrow_more(0, 1e18, borrower, address(0), "");
        vm.stopPrank();
        assertTrue(controller.loan_exists(borrower));
    }

    // --- Liquidation: the crvUSD legs, and the exit the docs call one token short ---------------
    //
    // The tGBP suite owns the economics modelling (step-down arms, sDOLA replay); what earns a
    // place here is what only this instance has. Hard liquidation's repay leg is crvUSD, not the
    // gem; and the liquidator's exit through redemption pays tGBP -- the borrowed token appears
    // nowhere in it. That mismatch is the subject of "The liquidation exit" in
    // docs/instances/wstgbp-crvusd.md, and these tests execute both halves of it.

    /// @dev The tGBP suite's documented edge (-10% in one publication), run against this market
    ///      to prove the crvUSD legs of clearing it: the liquidator pays crvUSD, receives wstGBP,
    ///      and redemption then pays tGBP -- leaving exactly the tGBP-to-crvUSD leg the instance
    ///      sheet prices from live venue depth, which no contract provides.
    function test_aNavCollapseHardLiquidatesInCrvUSDAndTheExitPaysTGBP() public {
        vm.startPrank(lender);
        IERC20(CRVUSD).approve(address(vault), type(uint256).max);
        vault.deposit(LIQUIDITY, lender);
        vm.stopPrank();

        uint256 max_ = controller.max_borrowable(COLLATERAL, N_BANDS, borrower);
        assertLt(max_, LIQUIDITY, "the loan must be collateral-limited, or the collapse moves nothing");
        uint256 debt_ = (max_ * 95) / 100;

        vm.startPrank(borrower);
        IERC20(WSGEM).approve(address(controller), type(uint256).max);
        controller.create_loan(COLLATERAL, debt_, N_BANDS, borrower, address(0), "");
        vm.stopPrank();
        assertGt(controller.health(borrower, true), 0);

        // The collapse: -10% in one publication, passed through undamped.
        _setNav((IWsgem(WSGEM).navprice() * 90) / 100);
        assertLt(controller.health(borrower, true), 0, "a 95%-of-max loan must be under water");

        // The repay leg. `tokens_to_liquidate` quotes crvUSD, and crvUSD is what leaves the
        // liquidator -- the gem funds nothing here, which is the assertion a tGBP-funded
        // liquidator (the tGBP suite's shape) could never make.
        uint256 need_ = controller.tokens_to_liquidate(borrower, 1e18);
        assertGt(need_, 0);
        deal(CRVUSD, liquidator, need_ + 1e18);
        vm.startPrank(liquidator);
        IERC20(CRVUSD).approve(address(controller), type(uint256).max);
        controller.liquidate(borrower, 0, 1e18);
        vm.stopPrank();

        assertFalse(controller.loan_exists(borrower));
        uint256 seized_ = IERC20(WSGEM).balanceOf(liquidator);
        assertGt(seized_, 0, "the liquidator must receive the collateral");
        assertApproxEqRel(
            need_ + 1e18 - IERC20(CRVUSD).balanceOf(liquidator),
            need_,
            0.01e18,
            "and must have paid for it in crvUSD, at the quoted amount"
        );
        assertEq(IERC20(GEM).balanceOf(liquidator), 0, "no tGBP has moved anywhere yet");

        // The exit. Redemption is live at the pinned block and pays the reported quote -- in
        // tGBP. The liquidator now holds sterling, still owing nothing, and the road from here
        // to crvUSD is the venue depth the instance sheet measures, not a contract.
        IWsgemRedeem w_ = IWsgemRedeem(WSGEM);
        assertTrue(w_.canPass(liquidator), "the compliance gate admits the liquidator");
        assertTrue(w_.burnable(), "the burn window is open");
        assertEq(w_.cooldown(), 0, "zero cooldown: settlement is atomic");

        uint256 quote_ = IWsgem(WSGEM).burncost();
        vm.prank(liquidator);
        w_.redeem(seized_);

        assertEq(IERC20(WSGEM).balanceOf(liquidator), 0);
        assertEq(
            IERC20(GEM).balanceOf(liquidator),
            (seized_ * quote_) / 1e18,
            "redemption pays exactly the quote, and it pays in tGBP -- not in what the debt was"
        );
    }

    /// @dev Soft liquidation under the driver only this instance has: sterling drifting down
    ///      through the bands, tick by unthrottled tick, with an arbitrageur converting as it
    ///      goes -- then a gap-sized round on the same book, which steps the price in one block
    ///      the way the instance sheet says a fast market or a Sunday reopen will.
    function test_anFxDriftSoftLiquidatesAndAGapStepsInOneBlock() public {
        vm.startPrank(lender);
        IERC20(CRVUSD).approve(address(vault), type(uint256).max);
        vault.deposit(LIQUIDITY, lender);
        vm.stopPrank();

        uint256 max_ = controller.max_borrowable(COLLATERAL, N_BANDS, borrower);
        uint256 debt_ = (max_ * 95) / 100;
        vm.startPrank(borrower);
        IERC20(WSGEM).approve(address(controller), type(uint256).max);
        controller.create_loan(COLLATERAL, debt_, N_BANDS, borrower, address(0), "");
        vm.stopPrank();

        deal(CRVUSD, arb, ARB_FUNDING);
        deal(WSGEM, arb, ARB_FUNDING);
        vm.startPrank(arb);
        IERC20(CRVUSD).approve(address(amm), type(uint256).max);
        IERC20(WSGEM).approve(address(amm), type(uint256).max);
        vm.stopPrank();

        (, int256 answer_,,,) = IChainlinkAggregator(cfg.FX_FEED()).latestRoundData();

        // Twelve daily rounds of -0.5%: each tick is under band width (~56 bp at A = 180), so
        // soft liquidation gets band-scale granularity. ~-5.8% cumulative walks into a
        // 95%-of-max book's bands, whose ten-band span reaches several percent further down --
        // which is what leaves the gap below bands to cross. Track the largest single-tick
        // conversion for the gap to be measured against.
        uint256 maxTickConverted_;
        for (uint256 d_; d_ < 12; ++d_) {
            skip(1 days);
            answer_ = (answer_ * 995) / 1000;
            _setFx(answer_);
            uint256 c0_ = controller.user_state(borrower)[1];
            _arbToward(oracle.price());
            uint256 ticked_ = controller.user_state(borrower)[1] - c0_;
            if (ticked_ > maxTickConverted_) maxTickConverted_ = ticked_;
        }

        assertTrue(controller.loan_exists(borrower), "drift is not a default");
        assertGt(
            controller.user_state(borrower)[1],
            0,
            "soft liquidation must have converted collateral to crvUSD in the AMM"
        );
        assertLt(
            controller.user_state(borrower)[0],
            COLLATERAL,
            "and the collateral left in the AMM must show the conversion"
        );

        // The gap: one -3% round on the same book. The conversion leg is deliberately
        // unthrottled, so the whole move lands in a single block -- more than four band widths
        // at once (~56 bp at A = 180) -- and the bands it crosses are crossed untraded: nothing
        // converts until the arbitrageur returns, and by then the price it converts at is the
        // gapped one. That is what "faster than soft liquidation can work" means.
        uint256 before_    = oracle.price();
        uint256 converted_ = controller.user_state(borrower)[1];

        _setFx((answer_ * 97) / 100);

        assertApproxEqRel(
            oracle.price(),
            (before_ * 97) / 100,
            1e15,
            "a gap-sized round steps the reported price in full, in one block"
        );
        assertGt(
            (before_ - oracle.price()) * uint256(cfg.A()),
            4 * before_,
            "the step must span several bands, or this gap proves nothing"
        );
        assertEq(
            controller.user_state(borrower)[1],
            converted_,
            "the bands the gap crossed were crossed untraded"
        );

        IAMMExchange(address(amm)).exchange(0, 1, 0, 0);
        assertEq(amm.price_oracle(), oracle.price(), "and the AMM anchors to the stepped price");

        // The conversion that follows is bulk, not metered. Not in the gap's own block --
        // LLAMMA's dynamic fee scales with how far the oracle just moved, so the same-block
        // trade prices as unprofitable, exactly as the tGBP suite's arb notes describe -- but
        // within the hour, as the fee decays, and then it is bigger than any metered daily tick.
        for (uint256 t_; t_ < 6; ++t_) {
            skip(10 minutes);
            _arbToward(oracle.price());
        }
        assertGt(
            controller.user_state(borrower)[1] - converted_,
            maxTickConverted_,
            "the gap's conversion arrives in bulk, bigger than any metered tick"
        );
    }

    // --- Helpers --------------------------------------------------------------------------------

    /// @notice Deposit vault liquidity and open a half-of-max loan for the borrower.
    function _lendAndBorrow() internal returns (uint256 debt_) {
        vm.startPrank(lender);
        IERC20(CRVUSD).approve(address(vault), type(uint256).max);
        vault.deposit(LIQUIDITY, lender);
        vm.stopPrank();

        debt_ = controller.max_borrowable(COLLATERAL, N_BANDS, borrower) / 2;

        vm.startPrank(borrower);
        IERC20(WSGEM).approve(address(controller), type(uint256).max);
        IERC20(CRVUSD).approve(address(controller), type(uint256).max);
        controller.create_loan(COLLATERAL, debt_, N_BANDS, borrower, address(0), "");
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

    /// @dev Same re-stamp the creation-time suite carries, for the same reason: a skip must not
    ///      let the pinned round's incidental age decide a test that is not about staleness.
    function _refreshFx() internal {
        IChainlinkAggregator f_ = IChainlinkAggregator(cfg.FX_FEED());
        (uint80 id_, int256 answer_,,, uint80 in_) = f_.latestRoundData();
        vm.mockCall(
            address(f_),
            abi.encodeCall(IChainlinkAggregator.latestRoundData, ()),
            abi.encode(id_, answer_, block.timestamp, block.timestamp, in_)
        );
    }

    /// @dev A fresh round at a chosen answer: the drift and gap tests' way of moving sterling.
    ///      Fresh-stamped for the same reason `_refreshFx` re-stamps -- these tests are about the
    ///      answer, not its age.
    function _setFx(int256 answer_) internal {
        IChainlinkAggregator f_ = IChainlinkAggregator(cfg.FX_FEED());
        (uint80 id_,,,, uint80 in_) = f_.latestRoundData();
        vm.mockCall(
            address(f_),
            abi.encodeCall(IChainlinkAggregator.latestRoundData, ()),
            abi.encode(id_, answer_, block.timestamp, block.timestamp, in_)
        );
    }

    /// @dev Same override the tGBP lifecycle suite uses: everything downstream reads through the
    ///      pip's one method, so the whole live stack still runs; only the number is ours.
    function _setNav(uint256 nav_) internal {
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(nav_));
        require(IWsgem(WSGEM).navprice() == nav_, "nav override did not take");
    }

    /// @dev Wallet-only worth in crvUSD at `p_` -- the arbitrageur never holds a position.
    function _plainWorth(address who_, uint256 p_) internal view returns (uint256) {
        return IERC20(CRVUSD).balanceOf(who_) + (IERC20(WSGEM).balanceOf(who_) * p_) / 1e18;
    }

    /// @notice Walk the AMM toward the oracle price, keeping only the trades that actually pay.
    /// @dev The tGBP suite's crude loop, re-marked in crvUSD -- see the long note there for why
    ///      the profitability test and the halving are both load-bearing. `coins(0)` is crvUSD
    ///      and `coins(1)` wstGBP; one chunk size serves both directions because the pair trades
    ///      near parity.
    function _arbToward(uint256 fair_) internal {
        uint256 chunk_ = ARB_CHUNK;

        for (uint256 k_; k_ < ARB_STEPS; ++k_) {
            uint256 p_ = amm.get_p();
            if (p_ == 0) return;
            if (p_ <= (fair_ * 10_010) / 10_000 && p_ >= (fair_ * 9_990) / 10_000) return;

            uint256 i_     = p_ > fair_ ? 1 : 0;
            uint256 worth_ = _plainWorth(arb, fair_);
            uint256 snap_  = vm.snapshotState();
            bool    kept_;

            vm.prank(arb);
            try IAMMExchange(address(amm)).exchange(i_, 1 - i_, chunk_, 0) returns (
                uint256[2] memory got_
            ) {
                kept_ = got_[1] > 0 && _plainWorth(arb, fair_) > worth_;
            } catch {
                kept_ = false;
            }

            if (kept_) continue;

            vm.revertToState(snap_);
            chunk_ /= 2;
            if (chunk_ < ARB_MIN_CHUNK) return;
        }
    }
}
