// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {WsgemFxLlamalendOracle} from "../../src/WsgemFxLlamalendOracle.sol";
import {WsgemLlamalendOracle}   from "../../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}    from "../../src/WsgemRateCalculator.sol";
import {IWsgem}                 from "../../src/interfaces/IWsgem.sol";
import {IPip}                   from "../../src/interfaces/IPip.sol";
import {IWsgemShimOracle}       from "../../src/interfaces/IWsgemShimOracle.sol";
import {IChainlinkAggregator}   from "../../src/interfaces/IChainlinkAggregator.sol";
import {IStablePriceAggregator} from "../../src/interfaces/IStablePriceAggregator.sol";
import {ILendFactory}           from "../../src/interfaces/ILendFactory.sol";
import {ILendController}        from "../../src/interfaces/ILendController.sol";
import {IConfigurator}          from "../../src/interfaces/IConfigurator.sol";
import {IVault}                 from "../../src/interfaces/IVault.sol";
import {IAMM}                   from "../../src/interfaces/IAMM.sol";
import {IHyperbolicDynamicMP}   from "../../src/interfaces/IMonetaryPolicy.sol";
import {IDecimals}              from "../../src/interfaces/IDecimals.sol";

import {WstGBPCrvUSDMarketScript} from "../../script/WstGBPCrvUSD.s.sol";
import {WstGBPMarketScript}       from "../../script/WstGBP.s.sol";

/// @dev This instance's internal validation, exposed so a live oracle can be run through the exact
///      path a broadcast takes.
contract CrvUSDForkHarness is WstGBPCrvUSDMarketScript {
    function assertOracle(address oracle_) external {
        _assertOracle(IWsgemShimOracle(oracle_));
    }
}

/// @dev The FIRST instance's validation, for the converse rejection.
contract CrvUSDTGBPForkHarness is WstGBPMarketScript {
    function assertOracle(address oracle_) external {
        _assertOracle(IWsgemShimOracle(oracle_));
    }
}

/// @notice The wstGBP/crvUSD instance against live mainnet state: the real wsgem, the real
///         Chainlink GBP/USD feed, the real Curve crvUSD aggregator and the real `LendFactory`.
/// @dev What the unit suite cannot show. Mocks prove the composition is the composition it says it
///      is; only this proves the addresses in `script/WstGBPCrvUSD.s.sol` are the contracts they
///      are claimed to be, that they answer in the shapes and scales assumed, and that a market
///      built on the result is accepted by Curve's factory.
///
///      Run with `make test-fork`, which hard-fails without a mainnet RPC rather than skipping.
contract WstGBPCrvUSDForkTest is Test {
    WstGBPCrvUSDMarketScript internal cfg;

    address internal WSGEM;
    address internal GEM;
    address internal FACTORY;
    address internal CONFIGURATOR;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));

        // Read the production constants from the production script rather than restating them, so
        // this suite cannot drift away from what will actually be deployed.
        cfg          = new WstGBPCrvUSDMarketScript();
        WSGEM        = cfg.WSGEM();
        GEM          = cfg.GEM();
        FACTORY      = cfg.FACTORY();
        CONFIGURATOR = cfg.CONFIGURATOR();
    }

    // --- The addresses are the contracts they are claimed to be --------------------------------

    function test_theBorrowedTokenIsWhatTheConfigSays() public view {
        assertEq(IDecimals(cfg.BORROWED()).decimals(), 18, "crvUSD is 18 decimals");
        assertTrue(cfg.BORROWED() != GEM, "the borrowed token is not the gem");
    }

    function test_theSterlingFeedIsGbpUsd() public view {
        IChainlinkAggregator f_ = IChainlinkAggregator(cfg.FX_FEED());
        assertEq(f_.decimals(), 8, "the config assumes 8 decimals and scales by 1e10");

        (, int256 answer_,, uint256 updatedAt_,) = f_.latestRoundData();
        assertGt(answer_, 0.5e8, "a plausible GBP/USD, not a different pair or scale");
        assertLt(answer_, 3e8);
        assertGt(updatedAt_, 0);
        assertLt(block.timestamp - updatedAt_, cfg.MAX_FX_AGE(), "fresh at the pin");
    }

    function test_theCrvUsdAggregatorAnswersInWadNearADollar() public view {
        uint256 p_ = IStablePriceAggregator(cfg.BORROWED_QUOTE()).price();
        assertGt(p_, 0.9e18, "a WAD dollar quote, not an 8-decimal one");
        assertLt(p_, 1.1e18);
    }

    // --- The composition -----------------------------------------------------------------------

    /// @dev The identity, computed independently of the contract from the same three live reads.
    function test_theOracleReportsTheComposedPrice() public {
        WsgemFxLlamalendOracle o_ = _deploy();

        (, int256 gbp_,,,) = IChainlinkAggregator(cfg.FX_FEED()).latestRoundData();
        assertGt(gbp_, 0);
        uint256 quote_ = IStablePriceAggregator(cfg.BORROWED_QUOTE()).price();

        // casting to 'uint256' is safe because the feed was asserted positive above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 gbpWad_ = uint256(gbp_) * 1e10;
        uint256 expected_ = (IWsgem(WSGEM).burncost() * gbpWad_) / quote_;

        assertEq(o_.price(), expected_, "burncost x GBP/USD / crvUSD");
        assertEq(o_.price(), o_.spotPrice(), "a fresh oracle is not rate-limited against itself");
    }

    /// @dev A sanity band on the answer itself, not just on the arithmetic. wstGBP is a little over
    ///      a pound and a pound is a little over a dollar, so the price belongs between them -- a
    ///      check that catches a scale error the algebraic identity above would happily reproduce.
    function test_theComposedPriceIsInAPlausibleBand() public {
        WsgemFxLlamalendOracle o_ = _deploy();
        assertGt(o_.price(), 1.1e18, "a pound is worth more than a dollar");
        assertLt(o_.price(), 2e18, "and not twice as much");
    }

    /// @dev The cross-currency price must be strictly above the same-currency one: a pound buys
    ///      more than a dollar, so wstGBP is worth more crvUSD than tGBP.
    function test_theCrossCurrencyPriceExceedsTheSameCurrencyOne() public {
        WstGBPMarketScript first_ = new WstGBPMarketScript();
        WsgemLlamalendOracle plain_ =
            new WsgemLlamalendOracle(IWsgem(WSGEM), first_.MAX_UPSIDE_SPEED());

        assertGt(_deploy().price(), plain_.price());
    }

    // --- Live failure drills -------------------------------------------------------------------

    function test_aHaltedSterlingFeedFreezesRatherThanReverting() public {
        WsgemFxLlamalendOracle o_ = _deploy();
        uint256 held_ = o_.price_w();

        // No new round for longer than the bound allows. Every other leg keeps working -- Curve's
        // aggregator has no publication time and cannot go stale.
        skip(cfg.MAX_FX_AGE() + 1);

        assertTrue(o_.fxFrozen(), "the conversion, not the wsgem, is what went dark");
        assertEq(o_.price(), held_, "the market keeps a price to repay and liquidate against");
        assertEq(o_.spotPrice(), 0);
        assertGt(o_.quotePrice(), 0, "and the wsgem's own leg still reports");
    }

    function test_aPausedWsgemFeedFreezesTheOracleToo() public {
        WsgemFxLlamalendOracle o_ = _deploy();
        uint256 held_ = o_.price_w();

        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(uint256(0)));

        assertTrue(o_.frozen());
        assertFalse(o_.fxFrozen(), "and names the wsgem's feed as the cause, not the conversion");
        assertEq(o_.price(), held_);
        assertGt(o_.fxRate(), 0, "while the conversion is still perfectly readable");
    }

    /// @dev What the observation window is for, run against the live stack on a synthetic clock: a
    ///      weekly-sized publication is absorbed gradually while a currency move is not.
    function test_aPublicationIsThrottledButACurrencyMoveIsNot() public {
        WsgemFxLlamalendOracle o_ = _deploy();
        uint256 anchor_ = o_.price_w();

        uint256 nav_ = IWsgem(WSGEM).navprice();
        _setNav(nav_ + (nav_ * 354) / 10_000 / 52); // one week at the observed ~3.54% APR

        assertGt(o_.spotPrice(), anchor_, "the step moved the live quote");
        assertEq(o_.price(), anchor_, "and is not expressed instantly");

        skip(12 hours);
        _refreshFx();
        assertEq(o_.price(), o_.spotPrice(), "half a day clears a weekly step at 0.25%/day");
    }

    // --- The whole deploy ----------------------------------------------------------------------

    function test_theMarketIsCreatedAndRegistered() public {
        (address vault_, address controller_, address amm_, address mp_, address oracle_, address calc_)
        = _createMarket();

        ILendFactory f_ = ILendFactory(FACTORY);
        ILendFactory.Market memory rec_ = f_.markets(f_.vaults_index(vault_));
        assertEq(rec_.collateral_token, WSGEM, "collateral is the wsgem");
        assertEq(rec_.borrowed_token, cfg.BORROWED(), "borrowed is NOT the gem");
        assertEq(rec_.price_oracle, oracle_);

        assertEq(IVault(vault_).asset(), cfg.BORROWED(), "the vault takes deposits in crvUSD");
        assertEq(IAMM(amm_).price_oracle_contract(), oracle_);
        assertEq(
            IAMM(amm_).price_oracle(),
            WsgemFxLlamalendOracle(oracle_).price(),
            "the AMM starts at the reported price"
        );
        assertEq(IAMM(amm_).A(), cfg.A());
        assertEq(IAMM(amm_).fee(), cfg.FEE());

        ILendController c_ = ILendController(controller_);
        assertEq(c_.borrowed_token(), cfg.BORROWED());
        assertEq(c_.loan_discount(), cfg.LOAN_DISCOUNT());
        assertEq(c_.liquidation_discount(), cfg.LIQUIDATION_DISCOUNT());
        assertEq(c_.borrow_cap(), 0, "a fresh market ships shut");

        assertEq(IHyperbolicDynamicMP(mp_).CONTROLLER(), controller_);
        assertEq(IHyperbolicDynamicMP(mp_).RATE_CALCULATOR(), calc_);
        assertEq(IHyperbolicDynamicMP(mp_).target_rate(), 317_097_920, "floors on a fresh calculator");
    }

    /// @dev The DAO vote is per market: opening this one opens nothing else.
    function test_thisMarketNeedsItsOwnBorrowCapVote() public {
        (, address controller_,,,,) = _createMarket();

        ILendFactory f_ = ILendFactory(FACTORY);
        vm.prank(f_.admin());
        IConfigurator(CONFIGURATOR).set_borrow_cap(controller_, 1_000_000e18);
        assertEq(ILendController(controller_).borrow_cap(), 1_000_000e18);
    }

    // --- A reused oracle must belong to THIS instance ------------------------------------------

    function test_thisInstanceAcceptsItsOwnLiveOracle() public {
        CrvUSDForkHarness h_ = new CrvUSDForkHarness();
        h_.assertOracle(address(_deploy()));
    }

    function test_theSameCurrencyLiveOracleIsRejected() public {
        WstGBPMarketScript first_ = new WstGBPMarketScript();
        WsgemLlamalendOracle plain_ =
            new WsgemLlamalendOracle(IWsgem(WSGEM), first_.MAX_UPSIDE_SPEED());

        CrvUSDForkHarness h_ = new CrvUSDForkHarness();
        vm.expectRevert();
        h_.assertOracle(address(plain_));
    }

    /// @dev And the converse, which matters just as much: the first instance must not accept this
    ///      one's oracle. Its `_assertOracleExtra` default states the same-currency identity --
    ///      undamped spot IS `burncost()` -- which a converted price fails.
    function test_theFirstInstanceRejectsThisOracle() public {
        // Deploy first: `expectRevert` arms the NEXT call, and the `new` inside `_deploy` would
        // be that call.
        address oracle_ = address(_deploy());

        CrvUSDTGBPForkHarness h_ = new CrvUSDTGBPForkHarness();
        vm.expectRevert(bytes("oracle: spot != burncost"));
        h_.assertOracle(oracle_);
    }

    // --- Helpers -------------------------------------------------------------------------------

    function _deploy() internal returns (WsgemFxLlamalendOracle) {
        return new WsgemFxLlamalendOracle(
            IWsgem(WSGEM),
            cfg.BORROWED(),
            IChainlinkAggregator(cfg.FX_FEED()),
            cfg.BORROWED_QUOTE(),
            cfg.BORROWED_QUOTE_KIND(),
            cfg.MAX_UPSIDE_SPEED(),
            cfg.MAX_FX_AGE()
        );
    }

    function _createMarket()
        internal
        returns (address vault_, address controller_, address amm_, address mp_, address oracle_, address calc_)
    {
        oracle_ = address(_deploy());
        calc_ = address(
            new WsgemRateCalculator(
                IWsgem(WSGEM), cfg.RATE_INTERVALS(), cfg.MAX_PUBLICATION_GAP(), cfg.MIN_CHECKPOINT_SPACING()
            )
        );

        address predicted_ = vm.computeCreateAddress(FACTORY, vm.getNonce(FACTORY) + 2);
        mp_ = _deployPolicy(predicted_, calc_);

        address[3] memory m_ = ILendFactory(FACTORY).create(
            cfg.BORROWED(),
            WSGEM,
            cfg.A(),
            cfg.FEE(),
            cfg.LOAN_DISCOUNT(),
            cfg.LIQUIDATION_DISCOUNT(),
            oracle_,
            mp_,
            cfg.SUPPLY_LIMIT()
        );

        (vault_, controller_, amm_) = (m_[0], m_[1], m_[2]);
        assertEq(controller_, predicted_, "controller mispredicted");
    }

    function _deployPolicy(address controller_, address calc_) internal returns (address mp_) {
        bytes memory code_ = abi.encodePacked(
            vm.parseBytes(vm.readFile("script/bytecode/HyperbolicDynamicMP.initcode.hex")),
            abi.encode(
                controller_,
                calc_,
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

    function _setNav(uint256 nav_) internal {
        vm.mockCall(IWsgem(WSGEM).pip(), abi.encodeCall(IPip.read, ()), abi.encode(nav_));
        require(IWsgem(WSGEM).navprice() == nav_, "nav override did not take");
    }

    /// @dev Re-stamp the live GBP/USD round at the current block, answer unchanged. For tests
    ///      that advance time but are not ABOUT staleness: the pinned round arrives carrying
    ///      whatever age it happened to have at the pin, so without this a synthetic skip can
    ///      push it over `MAX_FX_AGE` and turn a NAV-throttle test into a freeze test the moment
    ///      the pin moves.
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
