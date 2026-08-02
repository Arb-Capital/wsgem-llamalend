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
    uint256 internal constant SPACING   = 1 days;
    uint256 internal constant NAV0      = 1e18;

    MockPip              internal pip;
    MockGem              internal gem;
    MockWsgem            internal wsgem;
    WsgemLlamalendOracle internal oracle;
    WsgemRateCalculator  internal calc;
    WsgemShimHandler     internal handler;

    function setUp() public virtual {
        _setUp(SPEED, INTERVALS, GAP, SPACING, NAV0);
    }

    /// @dev Deploys the whole rig at an arbitrary legal configuration. Every invariant below
    ///      reads its bounds from the deployed contracts rather than the constants above, so a
    ///      subclass overriding `setUp` reruns the entire set at the constructor's
    ///      accept-boundaries -- see WsgemShimsEdgeConfigs.inv.t.sol.
    function _setUp(uint256 speed_, uint256 intervals_, uint256 gap_, uint256 spacing_, uint256 nav0_)
        internal
    {
        vm.warp(1_800_000_000);
        pip     = new MockPip(nav0_);
        gem     = new MockGem(18);
        wsgem   = new MockWsgem(address(gem), address(pip), 18);
        oracle  = new WsgemLlamalendOracle(IWsgem(address(wsgem)), speed_);
        calc    = new WsgemRateCalculator(IWsgem(address(wsgem)), intervals_, gap_, spacing_);
        handler = new WsgemShimHandler(oracle, calc, pip, wsgem);

        targetContract(address(handler));
    }

    /// @notice The oracle never reports zero, whatever the feed does.
    /// @dev `LendFactory.create` rejects a zero price, and an AMM that sees a zero mid-market
    ///      prices every position to nothing.
    function invariant_priceIsNeverZero() public view {
        assertGt(oracle.price(), 0);
        assertGt(handler.minReportedPrice(), 0);
    }

    /// @notice The oracle never reports above the live quote when there is one.
    /// @dev Under-valuing collateral is recoverable; over-valuing it creates bad debt. The sole,
    ///      wei-sized exception is intentional and outside this check's domain: a live feed
    ///      quoting exactly zero is reported as one wei, and the handler's ghost reads that
    ///      state as a zero spot and skips the comparison.
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

    /// @notice The reported price never rises faster than the configured limit, measured from
    ///         the last ANCHORED price.
    /// @dev The one-wei live-zero floor is the sole exception by design: it is reported without
    ///      being anchored, and recovery from it returns to the held anchor's ceiling in one
    ///      step. That round trip through a failure state never raises the admissible maximum,
    ///      which is why the ghost measures against the anchor.
    function invariant_upsideRateLimitHolds() public view {
        assertFalse(handler.rateLimitBreached());
    }

    /// @notice The reported price never exceeds the ceiling the checkpoint implies.
    function invariant_priceRespectsItsOwnCeiling() public view {
        uint256 spot_ = oracle.spotPrice();
        // Zero spot covers both failure states -- a pause holds the last report and a live-zero
        // quote reports one wei -- and the ceiling applies to neither, only to QUOTE reports.
        if (spot_ == 0) return;
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

    /// @notice Consecutive checkpoints are never closer than the spacing floor, so the
    ///         measurement denominator is bounded below by `intervals * floor` -- the property
    ///         that keeps any burst of republications or observations from collapsing the span
    ///         into a rate spike.
    function invariant_theSpacingFloorHoldsBetweenCheckpoints() public view {
        uint256 n_ = calc.intervalsMeasured();
        if (n_ < calc.MIN_INTERVALS()) return;

        (, uint256 oldTime_) = calc.oldestCheckpoint();
        (, uint256 newTime_) = calc.newestCheckpoint();
        assertGe(
            newTime_ - oldTime_,
            n_ * calc.MIN_CHECKPOINT_SPACING(),
            "a recorded gap undercut the floor"
        );
    }

    /// @notice The rate-limit anchor is never zero and its clock never runs backwards -- the
    ///         one storage slot the oracle owns stays internally coherent through every failure
    ///         state.
    function invariant_theAnchorIsNeverZeroAndItsClockNeverRegresses() public view {
        assertGt(oracle.cachedPrice(), 0, "the anchor must survive every episode nonzero");
        assertLe(oracle.cachedTimestamp(), block.timestamp);
        assertFalse(handler.cachedTimestampRegressed());
    }

    /// @notice A live-zero episode reports the one-wei floor without ever anchoring it: the
    ///         recovery anchor holds exactly where it stood when the episode began.
    /// @dev What makes recovery from a 100% spread return to the held anchor's ceiling instead
    ///      of ratcheting up from dust -- the mechanism behind the upside limit's sole
    ///      documented exception.
    function invariant_aLiveZeroEpisodeNeverPoisonsTheAnchor() public view {
        assertFalse(handler.anchorMovedDuringLiveZero());

        // While the flag is up and the feed is dark or still quoting zero, the report is the
        // floor itself. (Under a restored QUOTE the flag only clears on the next `price_w`.)
        if (oracle.liveZeroReported() && (oracle.frozen() || oracle.quoteIsZero())) {
            assertEq(oracle.price(), 1, "the witnessed floor holds until a real quote reports");
        }
    }

    /// @notice `frozen()` and `quoteIsZero()` mirror the feed exactly and never overlap: the
    ///         pip alone decides a freeze, the quote alone decides a live zero.
    function invariant_theFailureStateViewsMirrorTheFeed() public view {
        MockPip.Mode m_ = pip.mode();
        bool readable_  = m_ == MockPip.Mode.NORMAL || m_ == MockPip.Mode.LONG_RETURN;
        bool live_      = readable_ && pip.price() != 0;

        assertEq(oracle.frozen(), !live_, "frozen() must read the pip and nothing else");
        if (live_) {
            assertEq(oracle.quoteIsZero(), wsgem.burncost() == 0, "a live pip defers to the quote");
        } else {
            assertFalse(oracle.quoteIsZero(), "a dark feed is a freeze, never the zero-quote state");
        }
    }

    /// @notice `apr()` is exactly `rate()` annualised, saturating instead of overflowing --
    ///         under every configuration and feed state the run can produce.
    function invariant_aprIsTheSaturatingAnnualisationOfRate() public view {
        uint256 r_ = calc.rate();
        if (r_ == 0) {
            assertEq(calc.apr(), 0);
        } else if (r_ <= type(uint256).max / 365 days) {
            assertEq(calc.apr(), r_ * 365 days, "below saturation the annualisation is exact");
        } else {
            assertEq(calc.apr(), type(uint256).max, "past it the view saturates, never wraps");
        }
    }

    /// @notice `spotNav()` is the feed reading clamped at the storage bound, and zero through
    ///         every unreadable shape.
    function invariant_spotNavMirrorsTheFeed() public view {
        MockPip.Mode m_ = pip.mode();
        bool readable_  = m_ == MockPip.Mode.NORMAL || m_ == MockPip.Mode.LONG_RETURN;
        uint256 raw_    = pip.price();
        uint256 expected_ =
            readable_ ? (raw_ > type(uint208).max ? uint256(type(uint208).max) : raw_) : 0;
        assertEq(calc.spotNav(), expected_);
    }

    /// @notice `overdue()` flips exactly at the strict boundary, and the measured span is the
    ///         endpoint span plus exactly the overdue excess -- never approximately.
    function invariant_overdueAgreesWithTheSpanExtension() public view {
        (, uint256 newTime_) = calc.newestCheckpoint();
        uint256 due_ = newTime_ + calc.MAX_PUBLICATION_GAP();
        assertEq(calc.overdue(), block.timestamp > due_, "overdue is the strict boundary");

        uint256 n_ = calc.intervalsMeasured();
        if (n_ < calc.MIN_INTERVALS()) return;

        (, uint256 oldTime_) = calc.oldestCheckpoint();
        uint256 expected_ = newTime_ - oldTime_;
        if (block.timestamp > due_) expected_ += block.timestamp - due_;
        assertEq(calc.measuredSpan(), expected_, "the span extends by exactly the excess");
    }
}
