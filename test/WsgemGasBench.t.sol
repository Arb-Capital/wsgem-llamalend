// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../src/WsgemRateCalculator.sol";
import {IWsgem}               from "../src/interfaces/IWsgem.sol";
import {MockPip, MockGem, MockWsgem} from "./mocks/MockWsgem.sol";

/// @notice Gas benchmarks over the call paths a live market actually exercises, one test per
///         path. Written against the mock feed, so the absolute numbers undershoot mainnet
///         (the real pip sits behind a proxy) -- what these pin is the RELATIVE cost of each
///         path across a change. `forge test --match-contract WsgemGasBench` writes
///         `snapshots/WsgemGasBench.json`; diff it across a change to see what moved.
/// @dev Each test is its own transaction, so the shims' storage and accounts start cold,
///      exactly as they do for the first oracle read of a real user operation. Tests that
///      poke the pip before measuring warm the pip's account and price slot, which shaves a
///      few thousand off the measured feed read; the steady-state tests touch nothing first
///      and measure the true cold path.
contract WsgemGasBench is Test {
    uint256 internal constant WAD   = 1e18;
    uint256 internal constant NAV0  = 1.05e18;

    // The configured wstGBP parameters, from `script/WstGBP.s.sol`.
    uint256 internal constant SPEED     = uint256(0.0025e18) / 1 days;
    uint256 internal constant INTERVALS = 4;
    uint256 internal constant GAP       = 10 days;

    /// @dev The observed cadence, ~6.8 bp per week: 354 bp annualised over 52 weekly steps.
    uint256 internal constant APR_BPS = 354;

    MockPip              internal pip;
    MockGem              internal gem;
    MockWsgem            internal wsgem;
    WsgemLlamalendOracle internal oracle;
    WsgemRateCalculator  internal calc;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip    = new MockPip(NAV0);
        gem    = new MockGem(18);
        wsgem  = new MockWsgem(address(gem), address(pip), 18);
        oracle = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
        calc   = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP);

        // A month of live operation: weekly publications, the market touching both write
        // paths daily as the Controller and AMM would. Leaves the calculator with a full
        // measurement window and the oracle's anchor tracking the feed.
        for (uint256 w_; w_ < 5; ++w_) {
            for (uint256 d_; d_ < 7; ++d_) {
                skip(1 days);
                calc.rate_w();
                oracle.price_w();
            }
            _publish();
            calc.rate_w();
            oracle.price_w();
        }
    }

    /// @notice One weekly NAV step at the observed cadence.
    function _publish() internal {
        uint256 nav_ = pip.price();
        pip.poke(nav_ + (nav_ * APR_BPS) / 10_000 / 52);
    }

    // --- Oracle: normal operation --------------------------------------------------------------

    /// @notice The AMM's read path, cold storage: every user operation pays this at least once.
    function test_gas_oracle_price_coldRead() public {
        skip(12 hours);
        uint256 p_ = oracle.price();
        vm.snapshotGasLastCall("oracle.price cold");
        assertGt(p_, 0);
    }

    /// @notice A second read in the same transaction, everything warm: what each additional
    ///         `price()` inside one operation costs.
    function test_gas_oracle_price_warmSecondRead() public {
        skip(12 hours);
        oracle.price();
        uint256 p_ = oracle.price();
        vm.snapshotGasLastCall("oracle.price warm");
        assertGt(p_, 0);
    }

    /// @notice The AMM's write path between publications -- no price change, checkpoint
    ///         refresh only. The dominant `price_w` in a weekly-cadence market.
    function test_gas_oracle_priceW_steadyState() public {
        skip(12 hours);
        uint256 p_ = oracle.price_w();
        vm.snapshotGasLastCall("oracle.price_w steady");
        assertGt(p_, 0);
    }

    /// @notice The `price_w` that absorbs a weekly publication: anchor and checkpoint both
    ///         move. Once a week. (The poke pre-warms the pip, so the feed-read portion
    ///         measures a few thousand under its true cold cost.)
    function test_gas_oracle_priceW_absorbsPublication() public {
        skip(7 days);
        _publish();
        uint256 p_ = oracle.price_w();
        vm.snapshotGasLastCall("oracle.price_w publication");
        assertGt(p_, 0);
    }

    // --- Oracle: failure states ----------------------------------------------------------------

    /// @notice A paused feed, read path. Not normal operation -- benchmarked so the cost of a
    ///         failure state stays a recorded number rather than a guess.
    function test_gas_oracle_price_frozenFeed() public {
        skip(12 hours);
        pip.poke(0);
        uint256 p_ = oracle.price();
        vm.snapshotGasLastCall("oracle.price frozen");
        assertGt(p_, 0, "a freeze holds the last report");
    }

    /// @notice A paused feed, write path: what repayments pay through a pause.
    function test_gas_oracle_priceW_frozenFeed() public {
        skip(12 hours);
        pip.poke(0);
        uint256 p_ = oracle.price_w();
        vm.snapshotGasLastCall("oracle.price_w frozen");
        assertGt(p_, 0);
    }

    // --- Rate calculator -----------------------------------------------------------------------

    /// @notice The monetary policy's read path, cold storage.
    function test_gas_calc_rate_coldRead() public {
        skip(12 hours);
        uint256 r_ = calc.rate();
        vm.snapshotGasLastCall("calc.rate cold");
        assertGt(r_, 0);
    }

    /// @notice `rate_w` with no new publication: runs inside every borrow, repay and
    ///         liquidation via `save_rate`. The dominant write path.
    function test_gas_calc_rateW_noNewPublication() public {
        skip(12 hours);
        uint256 r_ = calc.rate_w();
        vm.snapshotGasLastCall("calc.rate_w steady");
        assertGt(r_, 0);
    }

    /// @notice The `rate_w` that records a publication: one ring write. Once a week. (Poke
    ///         pre-warms the pip here too.)
    function test_gas_calc_rateW_appendsCheckpoint() public {
        skip(7 days);
        _publish();
        uint256 before_ = calc.checkpointCount();
        uint256 r_ = calc.rate_w();
        vm.snapshotGasLastCall("calc.rate_w checkpoint");
        assertGt(r_, 0);
        assertEq(calc.checkpointCount(), before_ + 1, "the publication must actually record");
    }
}
