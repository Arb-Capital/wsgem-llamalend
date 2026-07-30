// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant}   from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../../src/WsgemRateCalculator.sol";
import {IWsgem}               from "../../src/interfaces/IWsgem.sol";
import {MockPip, MockGem, MockWsgem} from "../mocks/MockWsgem.sol";
import {WsgemShimHandler}     from "./handlers/WsgemShimHandler.sol";

/// @notice The properties a Llamalend market depends on, asserted across arbitrary sequences of
///         feed pokes, pauses, proxy breakages and time jumps.
/// @dev These are the claims the shims exist to make. Each corresponds to a way the market breaks
///      if it is false: a zero price bricks the AMM, an over-report over-values collateral, a
///      breached rate limit means a single poke can move the market, and a `price_w` divergence
///      makes the market unconstructible and then mispriced.
contract WsgemShimsInvariantTest is StdInvariant, Test {
    uint256 internal constant SPEED     = uint256(0.0025e18) / 1 days;
    uint256 internal constant INTERVALS = 4;
    uint256 internal constant GAP       = 10 days;
    uint256 internal constant NAV0      = 1e18;

    MockPip              internal pip;
    MockGem              internal gem;
    MockWsgem            internal wsgem;
    WsgemLlamalendOracle internal oracle;
    WsgemRateCalculator  internal calc;
    WsgemShimHandler     internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip     = new MockPip(NAV0);
        gem     = new MockGem(18);
        wsgem   = new MockWsgem(address(gem), address(pip), 18);
        oracle  = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
        calc    = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP);
        handler = new WsgemShimHandler(oracle, calc, pip);

        targetContract(address(handler));
    }

    /// @notice The oracle never reports zero, whatever the feed does.
    /// @dev `LendFactory.create` rejects a zero price, and an AMM that sees a zero mid-market
    ///      prices every position to nothing.
    function invariant_priceIsNeverZero() public view {
        assertGt(oracle.price(), 0);
        assertGt(handler.minReportedPrice(), 0);
    }

    /// @notice The oracle never reports above the live feed.
    /// @dev Under-valuing collateral is recoverable; over-valuing it is how bad debt is made.
    function invariant_priceNeverExceedsSpot() public view {
        assertFalse(handler.overReported());
    }

    /// @notice `price()` and `price_w()` always agree within a call.
    /// @dev Asserted twice: the handler checks it after every action in the run, and this repeats
    ///      it against whatever state the run finished in.
    function invariant_priceAndPriceWAgree() public {
        assertFalse(handler.priceWDiverged());

        uint256 p_ = oracle.price();
        assertEq(oracle.price_w(), p_);
    }

    /// @notice The reported price never rises faster than the configured limit.
    function invariant_upsideRateLimitHolds() public view {
        assertFalse(handler.rateLimitBreached());
    }

    /// @notice The reported price never exceeds the ceiling the checkpoint implies.
    function invariant_priceRespectsItsOwnCeiling() public view {
        uint256 spot_ = oracle.spotPrice();
        if (spot_ == 0) return; // frozen: reporting the cached price, ceiling does not apply
        assertLe(oracle.price(), oracle.priceCeiling());
    }

    /// @notice The calculator never manufactures yield: a rate is only ever reported when the NAV
    ///         actually rose across the measured window.
    /// @dev This, not a ceiling, is what the calculator can promise. A NAV that genuinely jumps 40x
    ///      has produced 40x of realised growth, and reporting that faithfully is correct -- the
    ///      monetary policy's own clamp to ~150% APR is what bounds the rate the market charges,
    ///      and it exists for exactly that case. That an ordinary publication cadence stays far
    ///      below the clamp is a property of realistic NAV movement rather than of arbitrary
    ///      sequences, so it is asserted where it can be stated precisely:
    ///      `testFuzz_aPlausibleYieldStaysInsideTheMonetaryPolicyClamp` drives a real weekly
    ///      cadence at 1-50% APR and pins the result inside the clamp at both ends.
    function invariant_rateIsNeverReportedWithoutGrowth() public view {
        assertFalse(handler.reportedYieldWithoutGrowth());
    }

    /// @notice No rate is reported until at least `MIN_INTERVALS` publications have been seen.
    /// @dev The guard against setting a borrow rate off a single publication, which a freshly
    ///      deployed calculator would otherwise do on the first NAV step it sees.
    function invariant_noRateIsReportedFromTooFewPublications() public view {
        if (!calc.measurable()) {
            assertEq(calc.rate(), 0);
            assertEq(calc.measuredSpan(), 0);
        }
        assertEq(calc.measurable(), calc.intervalsMeasured() >= calc.MIN_INTERVALS());
    }

    /// @notice The measurement never spans more intervals than configured, and never more than the
    ///         ring holds.
    /// @dev The ring-index arithmetic is the part of this contract most able to be silently wrong:
    ///      an off-by-one in `_indexBack` would read a checkpoint from the wrong end of the window
    ///      and report a rate from an interval that never happened.
    function invariant_theMeasuredWindowIsWellFormed() public view {
        uint256 n_ = calc.intervalsMeasured();
        assertLe(n_, calc.INTERVALS());
        assertLe(n_, calc.checkpointCount() - 1);

        if (n_ < calc.MIN_INTERVALS()) return;

        (uint256 oldNav_, uint256 oldTime_) = calc.oldestCheckpoint();
        (uint256 newNav_, uint256 newTime_) = calc.newestCheckpoint();

        assertGt(oldNav_, 0, "endpoint must be a real publication");
        assertGt(newNav_, 0, "endpoint must be a real publication");
        assertGe(newTime_, oldTime_, "the window must not run backwards");
        assertGe(calc.measuredSpan(), newTime_ - oldTime_, "span must cover the endpoints");
    }

    /// @notice The ring never holds a zero NAV, so the measurement window never has a zero
    ///         denominator waiting in it.
    function invariant_theRingNeverHoldsAZeroNav() public view {
        (uint256 oldest_,) = calc.oldestCheckpoint();
        (uint256 newest_,) = calc.newestCheckpoint();
        assertGt(oldest_, 0);
        assertGt(newest_, 0);
    }

    /// @notice The checkpoint count never exceeds the ring.
    function invariant_theRingNeverOverfills() public view {
        assertLe(calc.checkpointCount(), calc.SLOTS());
        assertGt(calc.checkpointCount(), 0);
    }
}
