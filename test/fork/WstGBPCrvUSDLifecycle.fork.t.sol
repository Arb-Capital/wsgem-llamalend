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

    address internal lender   = makeAddr("lender");
    address internal borrower = makeAddr("borrower");

    uint256 internal constant CAP        = 1_000_000e18;
    uint256 internal constant LIQUIDITY  = 100_000e18;
    uint256 internal constant COLLATERAL = 1_000e18;
    uint256 internal constant N_BANDS    = 10;

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
}
