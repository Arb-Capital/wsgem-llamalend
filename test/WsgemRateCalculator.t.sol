// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                from "forge-std/Test.sol";
import {WsgemRateCalculator} from "../src/WsgemRateCalculator.sol";
import {IWsgem}              from "../src/interfaces/IWsgem.sol";
import {MockPip, MockGem, MockWsgem} from "./mocks/MockWsgem.sol";

contract WsgemRateCalculatorTest is Test {
    uint256 internal constant WAD       = 1e18;
    uint256 internal constant INTERVALS = 4;
    uint256 internal constant GAP       = 10 days;
    uint256 internal constant SPACING   = 1 days; // the configured wstGBP checkpoint floor
    uint256 internal constant NAV0      = 1e18;

    /// @dev The observed cadence: ~6.8 bp per week, about 3.54% APR.
    uint256 internal constant STEP_BPS = 68; // in hundredths of a bp, i.e. 6.8bp

    /// @dev Curve's HyperbolicDynamicMP clamps whatever this contract reports into this range
    ///      before using it as the BASE rate; the final rate applies the utilization curve on
    ///      top, and the Controller caps what it charges at 300% APY.
    uint256 internal constant MP_MIN_RATE = 317_097_920;
    uint256 internal constant MP_MAX_RATE = 47_564_687_975;

    MockPip             internal pip;
    MockGem             internal gem;
    MockWsgem           internal wsgem;
    WsgemRateCalculator internal calc;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip   = new MockPip(NAV0);
        gem   = new MockGem(18);
        wsgem = new MockWsgem(address(gem), address(pip), 18);
        calc  = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, SPACING);
    }

    // --- Helpers -------------------------------------------------------------------------------

    /// @notice Run `weeks_` publication cycles at `aprBps_` annualised, with the Controller
    ///         touching `rate_w` daily as it would in a live market.
    function _runWeeks(uint256 weeks_, uint256 aprBps_) internal {
        for (uint256 w_; w_ < weeks_; ++w_) {
            for (uint256 d_; d_ < 7; ++d_) {
                skip(1 days);
                calc.rate_w();
            }
            uint256 nav_ = pip.price();
            pip.poke(nav_ + (nav_ * aprBps_) / 10_000 / 52);
            calc.rate_w();
        }
    }

    function _toApr(uint256 perSecond_) internal pure returns (uint256) {
        return perSecond_ * 365 days;
    }

    // --- Construction --------------------------------------------------------------------------

    function test_constructorCachesTheImmutableWiring() public view {
        assertEq(address(calc.WSGEM()), address(wsgem));
        assertEq(address(calc.PIP()), address(pip));
        assertEq(calc.INTERVALS(), INTERVALS);
        assertEq(calc.MAX_PUBLICATION_GAP(), GAP);
        assertEq(calc.MIN_CHECKPOINT_SPACING(), SPACING);
        assertEq(calc.checkpointCount(), 1);
    }

    function test_constructorRejectsAPausedFeed() public {
        pip.poke(0);
        vm.expectRevert(WsgemRateCalculator.OraclePaused.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, SPACING);
    }

    function test_constructorRejectsAZeroWsgem() public {
        vm.expectRevert(WsgemRateCalculator.ZeroAddress.selector);
        new WsgemRateCalculator(IWsgem(address(0)), INTERVALS, GAP, SPACING);
    }

    function test_constructorRejectsAWsgemWithAZeroPip() public {
        MockWsgem noPip_ = new MockWsgem(address(gem), address(0), 18);
        vm.expectRevert(WsgemRateCalculator.ZeroAddress.selector);
        new WsgemRateCalculator(IWsgem(address(noPip_)), INTERVALS, GAP, SPACING);
    }

    function test_constructorRejectsIntervalsOutOfRange() public {
        uint256 tooFew_  = calc.MIN_INTERVALS() - 1;
        uint256 tooMany_ = calc.SLOTS();

        vm.expectRevert(WsgemRateCalculator.IntervalsOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), tooFew_, GAP, SPACING);

        vm.expectRevert(WsgemRateCalculator.IntervalsOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), tooMany_, GAP, SPACING);
    }

    function test_constructorRejectsAGapOutOfRange() public {
        vm.expectRevert(WsgemRateCalculator.PublicationGapOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, 1 days - 1, 0);

        vm.expectRevert(WsgemRateCalculator.PublicationGapOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, 90 days + 1, SPACING);
    }

    /// @dev A floor at or above the grace would let the rate read overdue while a genuine
    ///      publication sat deferred behind the floor. Zero (no floor) is explicitly legal.
    function test_constructorRejectsASpacingNotBelowTheGap() public {
        vm.expectRevert(WsgemRateCalculator.SpacingOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, GAP);

        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, GAP - 1);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, 0);
    }

    function test_constructorAcceptsTheGapBoundaries() public {
        WsgemRateCalculator shortest_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, 1 days, 0);
        assertEq(shortest_.MAX_PUBLICATION_GAP(), 1 days);

        WsgemRateCalculator longest_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, 90 days, SPACING);
        assertEq(longest_.MAX_PUBLICATION_GAP(), 90 days);
    }

    function test_constructorAcceptsTheIntervalBoundaries() public {
        WsgemRateCalculator narrow_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), calc.MIN_INTERVALS(), GAP, SPACING);
        assertEq(narrow_.INTERVALS(), calc.MIN_INTERVALS());

        WsgemRateCalculator wide_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), calc.SLOTS() - 1, GAP, SPACING);
        assertEq(wide_.INTERVALS(), calc.SLOTS() - 1);
    }

    function test_constructorEmitsTheSeedCheckpoint() public {
        vm.expectEmit(true, true, false, true);
        emit Checkpointed(NAV0, 0);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, SPACING);
    }

    // --- The reason this contract exists -------------------------------------------------------

    /// @dev The failure mode a wall-clock window has: the denominator grows between publications
    ///      while the numerator does not, so the reported rate decays through the week and jumps
    ///      back on publication. Anchoring on publications makes it exactly constant instead.
    function test_theReportedRateIsExactlyConstantBetweenPublications() public {
        _runWeeks(8, 354);

        uint256 atPublication_ = calc.rate();
        assertGt(atPublication_, 0);

        for (uint256 d_; d_ < 6; ++d_) {
            skip(1 days);
            assertEq(calc.rate_w(), atPublication_, "rate must not move between publications");
        }
    }

    function test_measuresTheObservedCadenceCorrectly() public {
        _runWeeks(8, 354); // ~6.8 bp/week

        uint256 apr_ = _toApr(calc.rate());
        assertApproxEqRel(apr_, 0.0354e18, 0.02e18, "3.54% APR in, ~3.54% APR out");
    }

    function test_measuresAHigherYieldCorrectly() public {
        _runWeeks(8, 1200);
        assertApproxEqRel(_toApr(calc.rate()), 0.12e18, 0.02e18);
    }

    /// @dev The whole point of shortening the window: a policy-rate cut must reach borrowers
    ///      promptly rather than being averaged against two months of stale history.
    function test_aRateCutIsFullyTrackedWithinFourPublications() public {
        _runWeeks(8, 354);
        uint256 before_ = calc.rate();

        // Cut roughly in half, then run four fresh publications at the new pace.
        _runWeeks(4, 177);
        uint256 after_ = calc.rate();

        assertApproxEqRel(_toApr(after_), 0.0177e18, 0.05e18, "must reach the new rate, not average");
        assertLt(after_, before_);
    }

    function test_aRateCutIsMostlyTrackedAfterTwoPublications() public {
        _runWeeks(8, 354);
        uint256 before_ = calc.rate();

        _runWeeks(2, 177);
        uint256 mid_ = calc.rate();

        // Two of four intervals replaced, so roughly half way between old and new.
        assertLt(mid_, before_);
        assertGt(mid_, calc.rate() / 2);
        assertApproxEqRel(_toApr(mid_), 0.0265e18, 0.15e18, "~half way after two of four");
    }

    // --- Window management ---------------------------------------------------------------------

    function test_onlyPublicationsAreCheckpointed() public {
        uint256 before_ = calc.checkpointCount();
        for (uint256 i; i < 50; ++i) {
            skip(1 hours);
            calc.rate_w();
        }
        assertEq(before_, calc.checkpointCount(), "an unchanged NAV is not a publication");
    }

    function test_everyPublicationIsCheckpointedOnce() public {
        for (uint256 i; i < 5; ++i) {
            skip(7 days);
            pip.poke(pip.price() + 1e14);
            calc.rate_w();
            calc.rate_w(); // a second call in the same block must not double-record
        }
        assertEq(calc.checkpointCount(), 6);
    }

    function test_theRingFillsAndThenStopsGrowing() public {
        for (uint256 i; i < calc.SLOTS() * 2; ++i) {
            skip(7 days);
            pip.poke(pip.price() + 1e14);
            calc.rate_w();
        }
        assertEq(calc.checkpointCount(), calc.SLOTS());
    }

    function test_theWindowSpansExactlyFourPublicationIntervals() public {
        _runWeeks(8, 354);

        (, uint256 oldest_) = calc.oldestCheckpoint();
        (, uint256 newest_) = calc.newestCheckpoint();

        assertEq(calc.intervalsMeasured(), INTERVALS);
        assertEq(newest_ - oldest_, 4 * 7 days, "four whole intervals, no partial time");
        assertEq(calc.measuredSpan(), 4 * 7 days);
    }

    function test_measuresOverFewerIntervalsBeforeTheRingFills() public {
        _runWeeks(3, 354);
        assertEq(calc.intervalsMeasured(), 3);
        assertGt(calc.rate(), 0);
    }

    /// @dev A systematic lag in observing publications cancels: it shifts both endpoints equally.
    function test_systematicObservationLagCancels() public {
        _runWeeks(8, 354);
        uint256 prompt_ = calc.rate();

        // Rebuild with every publication observed two days late.
        pip.poke(NAV0);
        WsgemRateCalculator lagged_ = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, SPACING);
        for (uint256 w_; w_ < 8; ++w_) {
            uint256 nav_ = pip.price();
            pip.poke(nav_ + (nav_ * 354) / 10_000 / 52);
            skip(2 days);
            lagged_.rate_w();
            skip(5 days);
        }

        assertApproxEqRel(lagged_.rate(), prompt_, 0.02e18, "constant lag must cancel");
    }

    // --- Overdue decay -------------------------------------------------------------------------

    function test_theRateIsFlatThroughTheGracePeriod() public {
        _runWeeks(8, 354);
        uint256 atPublication_ = calc.rate();

        skip(GAP);
        assertEq(calc.rate(), atPublication_, "flat right up to the end of grace");
        assertFalse(calc.overdue());
    }

    function test_theRateDecaysOnceTheFeedIsOverdue() public {
        _runWeeks(8, 354);
        uint256 atPublication_ = calc.rate();

        skip(GAP + 28 days);
        assertTrue(calc.overdue());

        uint256 decayed_ = calc.rate();
        assertLt(decayed_, atPublication_, "an abandoned feed must not hold its last reading");
        assertGt(decayed_, 0);

        // Denominator grew from 28 days to 56, so the rate should have roughly halved.
        assertApproxEqRel(decayed_, atPublication_ / 2, 0.05e18);
    }

    function test_theRateDecaysTowardZeroOverALongOutage() public {
        _runWeeks(8, 354);
        skip(GAP + 3650 days);
        assertLt(_toApr(calc.rate()), 0.001e18, "ten years of silence must decay to nothing");
    }

    /// @dev Both the overdue flag and the span extension use the same strict `>` boundary: at
    ///      exactly `newest + GAP` the feed is still in grace and the measurement untouched;
    ///      one second later it is overdue and the denominator has grown by exactly that second.
    function test_overdueFlipsExactlyOneSecondPastTheGap() public {
        _runWeeks(8, 354);
        (uint256 oldNav_, uint256 oldTime_) = calc.oldestCheckpoint();
        (uint256 newNav_, uint256 newTime_) = calc.newestCheckpoint();
        uint256 endpointSpan_  = newTime_ - oldTime_;
        uint256 atPublication_ = calc.rate();

        vm.warp(newTime_ + GAP);
        assertFalse(calc.overdue(), "at the boundary the feed is still in grace");
        assertEq(calc.measuredSpan(), endpointSpan_, "and the span is the endpoints' alone");
        assertEq(calc.rate(), atPublication_);

        skip(1);
        assertTrue(calc.overdue(), "one second past the gap the feed is overdue");
        assertEq(calc.measuredSpan(), endpointSpan_ + 1, "the span extends by exactly the excess");
        assertEq(
            calc.rate(),
            (((newNav_ - oldNav_) * WAD) / oldNav_) / (endpointSpan_ + 1),
            "the rate uses the extended denominator from the first overdue second"
        );
    }

    /// @dev `apr()` is the exact saturating annualisation of `rate()` in every regime, the
    ///      overdue decay included -- it must shrink with the growing denominator, not hold the
    ///      at-publication figure.
    function test_aprDecaysExactlyWithTheOverdueSpan() public {
        _runWeeks(8, 354);
        uint256 aprAtPublication_ = calc.apr();

        skip(GAP + 14 days);
        assertTrue(calc.overdue());
        assertEq(calc.apr(), calc.rate() * 365 days, "apr is the exact annualisation while decaying");
        assertLt(calc.apr(), aprAtPublication_, "and it decays with the span");
        assertGt(calc.apr(), 0);
    }

    // --- Failure modes -------------------------------------------------------------------------

    function test_aFlatNavPaysNothing() public {
        skip(GAP);
        calc.rate_w();
        assertEq(calc.rate(), 0, "no publications is no yield");
    }

    function test_aFallingNavPaysNothingRatherThanUnderflowing() public {
        _runWeeks(8, 354);
        skip(7 days);
        pip.poke(NAV0 / 2);
        calc.rate_w();
        assertEq(calc.rate(), 0);
    }

    function test_theRateResumesOnceAFallRollsOutOfTheWindow() public {
        _runWeeks(8, 354);

        // One bad publication, down 50 bp -- more than the window's ~27 bp of accumulated yield,
        // so the endpoints see a net fall.
        skip(7 days);
        pip.poke((pip.price() * (10_000 - 50)) / 10_000);
        calc.rate_w();
        assertEq(calc.rate(), 0, "a window containing a net fall pays no yield");

        // Two good publications later the fall is still inside the window.
        _runWeeks(2, 354);
        assertEq(calc.rate(), 0, "still inside the window, still a net fall");

        // Four publications after the fall, it is the far endpoint's neighbour and out of the
        // measurement. The rate must resume at the cadence, not stay stuck.
        _runWeeks(2, 354);
        assertApproxEqRel(_toApr(calc.rate()), 0.0354e18, 0.05e18, "the rate must recover");
    }

    /// @dev The endpoint formula sees only net growth: a dip and recovery inside one window is
    ///      measured as the difference between the two endpoints, nothing more.
    function test_aDipAndRecoveryInsideTheWindowMeasureTheirNet() public {
        _runWeeks(8, 354);

        skip(7 days);
        uint256 dipped_ = (pip.price() * (10_000 - 20)) / 10_000;
        pip.poke(dipped_);
        calc.rate_w();

        skip(7 days);
        pip.poke((dipped_ * (10_000 + 40)) / 10_000);
        calc.rate_w();

        (uint256 oldNav_,) = calc.oldestCheckpoint();
        (uint256 newNav_,) = calc.newestCheckpoint();
        assertGt(calc.rate(), 0);
        assertEq(
            calc.rate(),
            (((newNav_ - oldNav_) * WAD) / oldNav_) / calc.measuredSpan(),
            "only the endpoints enter the measurement"
        );
    }

    /// @dev Only the feed key can publish this fast, so this is inside the trusted-feed model --
    ///      but the shape is why `MIN_CHECKPOINT_SPACING` exists: with the floor disabled, a
    ///      republication burst collapses the span and reads as an absurd per-second rate,
    ///      bounded only by Curve's policy clamp. Pinned on an ungated instance; the next test
    ///      is the production configuration absorbing the same burst.
    function test_withoutAFloorRapidRepublicationCollapsesTheSpanAndSpikesToTheClamp() public {
        WsgemRateCalculator open_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, 0);
        for (uint256 w_; w_ < 4; ++w_) {
            skip(7 days);
            pip.poke(pip.price() + (pip.price() * 68) / 1_000_000);
            open_.rate_w();
        }

        for (uint256 i; i < 4; ++i) {
            skip(1 minutes);
            pip.poke(pip.price() + (pip.price() * 10) / 10_000); // +10 bp per minute
            open_.rate_w();
        }

        uint256 r_ = open_.rate();
        assertGt(_toApr(r_), 100e18, "a collapsed span reads as an absurd APR");
        assertGt(r_, MP_MAX_RATE, "past the base-rate clamp: the policy and Controller caps bound what is charged");
    }

    /// @dev The same burst against the production floor: nothing records inside it, the old
    ///      window is undisturbed, and when the floor elapses the burst lands as ONE checkpoint
    ///      whose interval is at least the floor -- so the measured rate stays inside the clamp.
    function test_theFloorAbsorbsARepublicationBurst() public {
        _runWeeks(8, 354);
        uint256 before_ = calc.rate();
        uint256 count_  = calc.checkpointCount();

        for (uint256 i; i < 4; ++i) {
            skip(1 minutes);
            pip.poke(pip.price() + (pip.price() * 10) / 10_000);
            calc.rate_w();
        }
        assertEq(calc.checkpointCount(), count_, "inside the floor nothing records");
        assertEq(calc.rate(), before_, "and the measurement is undisturbed");

        skip(SPACING);
        calc.rate_w();
        assertGt(calc.rate(), before_, "the burst's growth is measured once the floor elapses");
        assertLt(calc.rate(), MP_MAX_RATE, "over at least a floor of time, so inside the clamp");
    }

    function test_anAlternatingFeedMeasuresItsNetWhichIsZero() public {
        _runWeeks(8, 354);
        uint256 nav_ = pip.price();

        // A period-two oscillation across an even window: the endpoints are equal, so no yield.
        // Stepped at the spacing floor, the fastest cadence the ring will record.
        for (uint256 i; i < 6; ++i) {
            skip(SPACING);
            pip.poke(i % 2 == 0 ? nav_ + 1e15 : nav_);
            calc.rate_w();
        }
        assertEq(calc.rate(), 0, "an oscillation has no net growth across an even window");
    }

    // --- The spacing floor ---------------------------------------------------------------------

    /// @dev The floor must be invisible at the publication cadence: a gated and an ungated
    ///      calculator driven through identical weekly history must agree exactly, call for
    ///      call. This is the property that makes the floor safe to ship against a weekly feed
    ///      it is never expected to touch.
    function test_theFloorIsInertAtThePublicationCadence() public {
        WsgemRateCalculator open_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, 0);

        for (uint256 w_; w_ < 8; ++w_) {
            for (uint256 d_; d_ < 7; ++d_) {
                skip(1 days);
                calc.rate_w();
                open_.rate_w();
                assertEq(calc.rate(), open_.rate(), "the floor must not move a weekly measurement");
            }
            uint256 nav_ = pip.price();
            pip.poke(nav_ + (nav_ * 354) / 10_000 / 52);
            calc.rate_w();
            open_.rate_w();
        }

        assertEq(calc.checkpointCount(), open_.checkpointCount());
        assertEq(calc.rate(), open_.rate());
        assertEq(calc.measuredSpan(), open_.measuredSpan());
    }

    /// @dev With the floor disabled every distinct reading is a publication, same-block ones
    ///      included -- the `0 < 0` comparison in the spacing gate is trivially false, which is
    ///      what "zero disables the floor" means. The views must stay total over whatever span
    ///      shape that produces, a fully same-block window included.
    function testFuzz_withTheFloorDisabledEveryDistinctPublicationRecords(uint256 seed_) public {
        WsgemRateCalculator open_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, 0);

        uint256 expected_ = 1; // the seed
        for (uint256 i_; i_ < 12; ++i_) {
            uint256 entropy_ = uint256(keccak256(abi.encode(seed_, i_)));
            skip(entropy_ % 3 days); // zero included: a same-block distinct NAV must record
            pip.poke(NAV0 + (i_ + 1) * 1e14);
            open_.rate_w();

            expected_ = expected_ < open_.SLOTS() ? expected_ + 1 : expected_;
            assertEq(open_.checkpointCount(), expected_, "every distinct NAV records at once");

            // Steps stay under 3 days against a 10-day grace, so the feed is never overdue and
            // the span, when measurable, is exactly the endpoints' difference -- zero included.
            open_.rate();
            open_.apr();
            if (open_.measurable()) {
                (, uint256 oldTime_) = open_.oldestCheckpoint();
                (, uint256 newTime_) = open_.newestCheckpoint();
                assertEq(open_.measuredSpan(), newTime_ - oldTime_);
            } else {
                assertEq(open_.measuredSpan(), 0);
            }
        }
    }

    /// @dev The furthest the last test's collapse can go: with the floor disabled a window can
    ///      fall entirely into one block, both endpoints sharing a timestamp. A zero denominator
    ///      must read as no yield, never as a division error inside a market operation.
    function test_aFullySameBlockWindowReadsZeroRateNotDivisionByZero() public {
        WsgemRateCalculator open_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), 2, GAP, 0);

        skip(1 days);
        for (uint256 i = 1; i <= 3; ++i) {
            pip.poke(NAV0 + i * 1e14);
            open_.rate_w();
        }

        assertTrue(open_.measurable(), "three same-block publications fill a two-interval window");
        assertEq(open_.measuredSpan(), 0, "both endpoints share a block");
        assertEq(open_.rate(), 0, "a zero denominator is no yield, not a division error");
        assertEq(open_.apr(), 0);
    }

    /// @dev Deferred, not dropped: publications observed inside the floor telescope into the
    ///      latest NAV, which is recorded exactly when the boundary becomes eligible.
    function test_aDeferredPublicationIsRecordedOnceTheFloorElapses() public {
        _runWeeks(4, 354);
        uint256 count_ = calc.checkpointCount();

        skip(1 hours);
        uint256 first_ = pip.price() + 1e14;
        pip.poke(first_);
        calc.rate_w();
        assertEq(calc.checkpointCount(), count_, "inside the floor: deferred");

        // A further publication replaces the pending value rather than creating another entry.
        // One second below the floor is still ineligible.
        skip(SPACING - 1 hours - 1);
        uint256 latest_ = first_ + 2e14;
        pip.poke(latest_);
        calc.rate_w();
        assertEq(calc.checkpointCount(), count_, "one second below the floor: still deferred");

        skip(1);
        calc.rate_w();
        assertEq(calc.checkpointCount(), count_ + 1, "at the floor: recorded");

        (uint256 nav_, uint256 t_) = calc.newestCheckpoint();
        assertEq(nav_, latest_, "deferred publications telescope into the latest NAV");
        assertEq(t_, block.timestamp, "stamped at observation");
    }

    /// @dev The floor is direction-blind: a downward correction inside it is deferred exactly
    ///      like a rise, so the previous, higher measurement holds until the first rate_w past
    ///      the floor. The floor is when recording becomes eligible, not when it happens -- with
    ///      no call the stale reading persists, as any unobserved publication always has, and
    ///      rate_w is permissionless, so anyone can end it the moment the floor elapses.
    ///      Deliberate, not an oversight -- a floor that let falls through early could be packed
    ///      by a down-then-up sequence into the collapsed span it exists to prevent.
    function test_aFallInsideTheFloorIsDeferredLikeAnyOtherChange() public {
        _runWeeks(6, 354);
        uint256 before_ = calc.rate();
        uint256 count_  = calc.checkpointCount();
        assertGt(before_, 0);

        // A correction lands an hour after a publication, wiping more than the window's
        // accumulated growth.
        skip(1 hours);
        pip.poke((pip.price() * (10_000 - 50)) / 10_000);
        calc.rate_w();
        assertEq(calc.checkpointCount(), count_, "a fall inside the floor is deferred too");
        assertEq(calc.rate(), before_, "so the prior measurement holds while the floor runs");

        // Eligibility is not recording: three quiet days past the floor, the stale rate still
        // stands, because nothing has called to record the fall.
        skip(3 days);
        assertEq(calc.rate(), before_, "no call, no recording: staleness outlives the floor");

        calc.rate_w();
        assertEq(calc.checkpointCount(), count_ + 1, "the first call past the floor records");
        assertEq(calc.rate(), 0, "and a window containing a net fall pays no yield");
    }

    /// @dev The one place the floor binds at the weekly cadence: the deploy ramp. The seed is
    ///      stamped at deployment, so a publication landing inside a floor of deploy is deferred
    ///      and recorded with a later timestamp than an ungated calculator gives it. Under the
    ///      daily observation driven here, the divergence surfaces exactly once -- when that
    ///      checkpoint becomes the far endpoint -- is proportionally small (the deferral over
    ///      the window, ~3.7% here), and heals the moment the endpoint advances. Sparser calls
    ///      telescope the publications into one checkpoint instead; docs/03 covers that shape.
    ///      In the expected launch sequence all of this predates the Curve DAO vote that lifts
    ///      the zero borrow cap; nothing enforces that ordering, and the bounded size is what
    ///      makes it safe either way.
    function test_theDeployRampIsTheOnePlaceTheFloorBindsAtTheCadence() public {
        WsgemRateCalculator open_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, 0);

        // The publication cycle is mid-flight at deploy: the next one lands an hour later.
        skip(1 hours);
        uint256 nav_ = pip.price();
        pip.poke(nav_ + (nav_ * 354) / 10_000 / 52);
        calc.rate_w();
        open_.rate_w();
        assertEq(open_.checkpointCount(), 2, "ungated: recorded at once");
        assertEq(calc.checkpointCount(), 1, "gated: deferred behind the floor");

        // The feed holds P1's phase: every later publication lands exactly seven days after the
        // previous one, independent of when the deferred observation records -- which is the
        // first daily observation past the floor, a day into the first interval.
        for (uint256 p_ = 2; p_ <= 6; ++p_) {
            for (uint256 d_; d_ < 7; ++d_) {
                skip(1 days);
                calc.rate_w();
                open_.rate_w();
            }
            nav_ = pip.price();
            pip.poke(nav_ + (nav_ * 354) / 10_000 / 52);
            calc.rate_w();
            open_.rate_w();

            if (p_ == 2) {
                assertEq(
                    calc.checkpointCount(),
                    open_.checkpointCount(),
                    "the deferred publication caught up within the first interval"
                );
            }
            if (p_ < 5) {
                // The seed, identical in both, is still the far endpoint.
                assertEq(calc.rate(), open_.rate(), "seed-anchored windows agree exactly");
            } else if (p_ == 5) {
                // The deferred checkpoint is the far endpoint: same NAV, a span shorter by the
                // deferral, a rate higher by that ratio.
                assertGt(calc.rate(), open_.rate(), "the deferral surfaces, once");
                assertApproxEqRel(calc.rate(), open_.rate(), 0.04e18, "and stays proportional");
            } else {
                assertEq(calc.rate(), open_.rate(), "one publication later it has healed");
                assertEq(calc.measuredSpan(), open_.measuredSpan(), "spans agree again");
            }
        }
    }

    /// @dev The other regime, and the reason the floor exists: a feed that accrues every block
    ///      (here hourly, against a one-day floor). Checkpoints fall back to the floor, the
    ///      window becomes a rolling `INTERVALS * MIN_CHECKPOINT_SPACING` of realised yield,
    ///      and the measurement stays exact -- the bridge that survives a feed upgrade with no
    ///      redeploy and no governance action.
    function test_continuousAccrualFallsBackToTheFloorAndMeasuresExactly() public {
        uint256 perHour_ = uint256(0.04e18) / 365 / 24; // ~4% APR, accrued hourly

        for (uint256 h_ = 1; h_ <= 9 * 24; ++h_) {
            skip(1 hours);
            uint256 nav_ = pip.price();
            pip.poke(nav_ + (nav_ * perHour_) / WAD);
            calc.rate_w();
        }

        assertEq(calc.intervalsMeasured(), INTERVALS);
        assertEq(calc.measuredSpan(), INTERVALS * SPACING, "the window rides the floor");
        assertApproxEqRel(_toApr(calc.rate()), 0.04e18, 0.02e18, "4% APR in, ~4% APR out");
    }

    /// @dev The real fallback will not land on neat hourly updates or exact daily observations.
    ///      Drive continuous accrual with independently irregular update and `rate_w` timing, and
    ///      pin both sides of the intended degradation: the window cannot collapse below the
    ///      floor, but observation jitter does not make the measured yield drift from the feed.
    function testFuzz_irregularContinuousAccrualAndObservationStayAccurate(uint256 seed_) public {
        uint256 perSecond_ = uint256(0.04e18) / 365 days; // ~4% APR, accrued on every update
        uint256 sinceCall_;
        uint256 callAfter_ = 6 hours;

        // At least ten days of history. Updates land every 2-12 hours, while observations follow
        // an independent 3-18 hour schedule. A call can therefore fall just below the floor and
        // defer until the next irregular call rather than checkpointing on exact daily buckets.
        for (uint256 i_; i_ < 120; ++i_) {
            uint256 entropy_ = uint256(keccak256(abi.encode(seed_, i_)));
            uint256 dt_      = 2 hours + (entropy_ % 10 hours);

            skip(dt_);
            uint256 nav_ = pip.price();
            pip.poke(nav_ + (nav_ * perSecond_ * dt_) / WAD);

            sinceCall_ += dt_;
            if (sinceCall_ >= callAfter_) {
                calc.rate_w();
                sinceCall_  = 0;
                callAfter_  = 3 hours + ((entropy_ >> 128) % 15 hours);
            }
        }

        assertEq(calc.intervalsMeasured(), INTERVALS, "irregular sampling must fill the window");

        (uint256 oldNav_, uint256 oldTime_) = calc.oldestCheckpoint();
        (uint256 newNav_, uint256 newTime_) = calc.newestCheckpoint();
        uint256 span_ = newTime_ - oldTime_;

        assertGe(span_, INTERVALS * SPACING, "the floor bounds the denominator");
        assertLt(span_, 9 days, "observation jitter must not leave a stale window");
        assertEq(calc.measuredSpan(), span_, "the live feed remains inside its grace");
        assertEq(
            calc.rate(),
            (((newNav_ - oldNav_) * WAD) / oldNav_) / span_,
            "irregular sampling must still measure the endpoints exactly"
        );
        assertApproxEqRel(_toApr(calc.rate()), 0.04e18, 0.02e18, "4% APR in, ~4% APR out");
    }

    /// @dev The constructor's seed checkpoint is a mid-cycle observation: its NAV belongs to the
    ///      previous publication but its timestamp is the deploy block, so until it leaves the
    ///      window the measured span is short by up to one publication interval and the rate is
    ///      overstated by up to INTERVALS/(INTERVALS-1). That is accepted -- a new market's
    ///      borrow cap is zero through exactly this period -- but pinned here so it stays a
    ///      choice rather than a surprise.
    function test_theDeploySeedOverstatesEarlyAndCorrectsWhenItLeavesTheWindow() public {
        WsgemRateCalculator fresh_ = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP, SPACING);

        // The next publication lands a day after deploy; weekly thereafter.
        skip(1 days);
        for (uint256 i; i < 4; ++i) {
            uint256 nav_ = pip.price();
            pip.poke(nav_ + (nav_ * 354) / 10_000 / 52);
            fresh_.rate_w();
            if (i < 3) skip(7 days);
        }

        // Four publications of growth measured across three weeks and a day: ~28/22 overstated.
        assertApproxEqRel(_toApr(fresh_.rate()), (uint256(0.0354e18) * 28) / 22, 0.05e18);

        // The fifth publication pushes the seed out of the window and the measurement corrects.
        skip(7 days);
        uint256 n_ = pip.price();
        pip.poke(n_ + (n_ * 354) / 10_000 / 52);
        fresh_.rate_w();
        assertApproxEqRel(_toApr(fresh_.rate()), 0.0354e18, 0.05e18);
    }

    function test_aGasBombFeedIsCappedAndAbsorbed() public {
        _runWeeks(8, 354);
        uint256 rate_  = calc.rate();
        uint256 count_ = calc.checkpointCount();

        pip.setMode(MockPip.Mode.GAS_BOMB);
        uint256 g0_ = gasleft();
        calc.rate_w();
        assertLt(g0_ - gasleft(), calc.PIP_READ_GAS() + 50_000, "the read must never forward more than PIP_READ_GAS");
        assertEq(calc.rate(), rate_, "a burning feed holds the measurement, like a pause");
        assertEq(calc.checkpointCount(), count_);
    }

    function test_aReturndataBombFeedIsAbsorbed() public {
        _runWeeks(8, 354);
        uint256 count_ = calc.checkpointCount();

        pip.setMode(MockPip.Mode.RETURNDATA_BOMB);
        calc.rate_w();
        assertEq(calc.checkpointCount(), count_, "an oversized payload must never be recorded");
        assertGt(calc.rate(), 0);
    }

    function test_aPausedFeedIsNotCheckpointed() public {
        _runWeeks(8, 354);
        (uint256 navBefore_,) = calc.newestCheckpoint();

        pip.poke(0);
        skip(7 days);
        calc.rate_w();

        (uint256 navAfter_,) = calc.newestCheckpoint();
        assertEq(navAfter_, navBefore_, "a zero NAV must never enter the ring");
    }

    function test_anUnreadableFeedNeitherRevertsNorRecords() public {
        _runWeeks(8, 354);
        uint256 before_ = calc.checkpointCount();

        pip.setMode(MockPip.Mode.REVERTING);

        // Called from inside every borrow, repay and liquidation. Must not revert.
        calc.rate();
        calc.rate_w();
        assertEq(calc.checkpointCount(), before_);
    }

    /// @dev A pause holds the last measurement through grace, then decays it -- rather than
    ///      zeroing the borrow rate the instant a publication is late.
    function test_aPauseHoldsThenDecaysRatherThanZeroing() public {
        _runWeeks(8, 354);
        uint256 atPublication_ = calc.rate();

        pip.poke(0);
        skip(GAP - 1 days);
        assertEq(calc.rate(), atPublication_);

        skip(60 days);
        assertLt(calc.rate(), atPublication_);
        assertGt(calc.rate(), 0);
    }

    function test_noRateBeforeTwoPublications() public {
        assertFalse(calc.measurable());
        assertEq(calc.rate(), 0);

        skip(7 days);
        pip.poke(NAV0 + 1e14);
        calc.rate_w();
        assertFalse(calc.measurable(), "one publication is not a measurement");
        assertEq(calc.rate(), 0);

        skip(7 days);
        pip.poke(pip.price() + 1e14);
        calc.rate_w();
        assertTrue(calc.measurable());
        assertGt(calc.rate(), 0);
    }

    function test_aprViewMatchesTheAnnualisedRate() public {
        _runWeeks(8, 354);

        // Annualised by hand from the raw endpoints rather than from `rate()`, and checked
        // against the configured cadence, so this cannot degrade into the implementation
        // restated.
        (uint256 oldNav_,) = calc.oldestCheckpoint();
        (uint256 newNav_,) = calc.newestCheckpoint();
        // The divisions come first deliberately: this mirrors the production rounding order, so
        // the equality below is exact rather than approximate.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 expected_ = ((((newNav_ - oldNav_) * WAD) / oldNav_) / calc.measuredSpan()) * 365 days;

        assertEq(calc.apr(), expected_);
        assertApproxEqRel(calc.apr(), 0.0354e18, 0.02e18, "and it must sit at the fed cadence");
    }

    function test_aprSaturatesRatherThanReverting() public {
        // One wei of old NAV against the largest delta the overflow guard admits, over one-second
        // spans: the per-second rate is astronomical and annualising it overflows. The view must
        // saturate -- a convenience view that can revert is a view that breaks a block explorer.
        pip.poke(1);
        WsgemRateCalculator c_ = new WsgemRateCalculator(IWsgem(address(wsgem)), 2, GAP, 0);

        skip(1);
        pip.poke(2);
        c_.rate_w();

        skip(1);
        pip.poke(type(uint256).max / WAD);
        c_.rate_w();

        assertGt(c_.rate(), 0, "the rate itself is representable");
        assertEq(c_.apr(), type(uint256).max, "its annualisation is not, and must saturate");
    }

    /// @dev Exercises the production overflow guard (`delta_ > type(uint256).max / WAD`) and the
    ///      saturating uint208 store in one scenario: the reachable path to an absurd delta is a
    ///      saturated NAV against a tiny old one.
    function test_anAbsurdNavDeltaReadsAsZeroRatherThanOverflowing() public {
        pip.poke(1);
        WsgemRateCalculator c_ = new WsgemRateCalculator(IWsgem(address(wsgem)), 2, GAP, SPACING);

        skip(1 days);
        pip.poke(2);
        c_.rate_w();

        skip(1 days);
        pip.poke(type(uint256).max);
        c_.rate_w();

        (uint256 newNav_,) = c_.newestCheckpoint();
        assertEq(newNav_, uint256(type(uint208).max), "a monstrous NAV saturates, never wraps");
        assertEq(c_.rate(), 0, "a delta past the overflow guard is garbage, not yield");
        assertEq(c_.apr(), 0);
    }

    /// @dev Once the stored NAV is saturated, every further reading at or above the clamp
    ///      compares equal to it and is silently not a publication: the plateau is one
    ///      checkpoint, not many. A fall below the clamp ends it. The saturation happens at the
    ///      read, so the event and the ring agree -- both carry the clamp, never the raw reading.
    function test_aSaturatedNavDefersFurtherSaturatedReadingsUntilTheFeedFalls() public {
        _runWeeks(8, 354); // eight publications walk the head back to slot 0

        skip(7 days);
        pip.poke(type(uint256).max);
        vm.expectEmit(true, true, false, true, address(calc));
        emit Checkpointed(uint256(type(uint208).max), 1);
        calc.rate_w();
        (uint256 nav_, uint256 t_) = calc.newestCheckpoint();
        assertEq(nav_, uint256(type(uint208).max), "the ring stores the clamp, not the reading");

        skip(SPACING);
        pip.poke(type(uint256).max - 1);
        calc.rate_w();
        (, uint256 tAfter_) = calc.newestCheckpoint();
        assertEq(tAfter_, t_, "a saturated plateau records nothing further");

        skip(SPACING);
        pip.poke(NAV0);
        calc.rate_w();
        (uint256 navAfter_,) = calc.newestCheckpoint();
        assertEq(navAfter_, NAV0, "a fall below the clamp is a publication again");
    }

    /// @dev Unreachable by construction -- the constructor refuses a zero seed and `_checkpoint`
    ///      never records a zero -- so the `old_.nav == 0` guard in `_rate` is defence in depth.
    ///      Corrupt the ring directly to pin what it defends: a zero denominator waiting in the
    ///      window reads as no yield, never as a revert propagated into every market operation.
    function test_aZeroNavInTheRingWouldReadAsZeroRateNotRevert() public {
        skip(7 days);
        pip.poke(NAV0 + 1e14);
        calc.rate_w();
        skip(7 days);
        pip.poke(NAV0 + 2e14);
        calc.rate_w();
        assertGt(calc.rate(), 0);

        // The oldest endpoint is the constructor's seed in ring slot 0, the contract's first
        // storage slot: zero its NAV, keep its timestamp (bits 208+).
        (, uint256 seedTime_) = calc.oldestCheckpoint();
        vm.store(address(calc), bytes32(uint256(0)), bytes32(seedTime_ << 208));
        (uint256 oldNav_,) = calc.oldestCheckpoint();
        assertEq(oldNav_, 0, "the corruption landed where the measurement will look");

        assertEq(calc.rate(), 0, "a zero denominator is no yield, not a division error");
        assertEq(calc.apr(), 0);
    }

    // --- Views ---------------------------------------------------------------------------------

    function test_spotNavMirrorsTheFeedAndItsFailureStates() public {
        assertEq(calc.spotNav(), NAV0);

        pip.poke(type(uint256).max);
        assertEq(calc.spotNav(), uint256(type(uint208).max), "saturated, never wrapped");

        pip.poke(0);
        assertEq(calc.spotNav(), 0);

        pip.setMode(MockPip.Mode.REVERTING);
        assertEq(calc.spotNav(), 0);
    }

    /// @dev Below `MIN_INTERVALS` there is no far end to reach for, so `oldestCheckpoint()`
    ///      returns the head from both ends rather than reading an unwritten slot.
    function test_oldestCheckpointEqualsNewestBeforeMeasurability() public {
        (uint256 oldNav_, uint256 oldTime_) = calc.oldestCheckpoint();
        (uint256 newNav_, uint256 newTime_) = calc.newestCheckpoint();
        assertEq(oldNav_, newNav_, "the seed alone: both ends are the head");
        assertEq(oldTime_, newTime_);

        skip(7 days);
        pip.poke(NAV0 + 1e14);
        calc.rate_w();
        assertFalse(calc.measurable(), "one publication is still one short");
        (oldNav_, oldTime_) = calc.oldestCheckpoint();
        (newNav_, newTime_) = calc.newestCheckpoint();
        assertEq(oldNav_, newNav_, "still the head from both ends");
        assertEq(oldTime_, newTime_);
    }

    /// @dev Overdue and unmeasurable are independent states and every view must stay coherent
    ///      in their intersection: a fresh calculator left silent goes overdue with nothing to
    ///      measure, and everything reads zero rather than reaching for a window that is not
    ///      there.
    function test_viewsAreCoherentWhileOverdueAndUnmeasurable() public {
        skip(GAP + 30 days);
        assertTrue(calc.overdue(), "the seed alone can go overdue");
        assertEq(calc.intervalsMeasured(), 0);
        assertEq(calc.measuredSpan(), 0, "no window, no span, however overdue");
        assertEq(calc.rate(), 0);
        assertEq(calc.apr(), 0);
    }

    // --- Events ----------------------------------------------------------------------------------

    event Checkpointed(uint256 indexed nav, uint256 indexed slot);

    function test_checkpointedEmitsTheSlotItWroteThroughAWrap() public {
        // Nine publications walk the head through every slot and back past zero: slot 0 was the
        // constructor's, so publication i lands in slot i mod 8.
        for (uint256 i = 1; i <= 9; ++i) {
            skip(7 days);
            uint256 nav_ = NAV0 + i * 1e14;
            pip.poke(nav_);
            vm.expectEmit(true, true, false, true, address(calc));
            emit Checkpointed(nav_, i % 8);
            calc.rate_w();
        }
    }

    // --- Permissionlessness ------------------------------------------------------------------------

    function test_rateWIsCallableByAnyArbitraryAddress() public {
        skip(7 days);
        pip.poke(NAV0 + 1e14);

        vm.prank(address(0xBEEF));
        calc.rate_w();
        assertEq(calc.checkpointCount(), 2, "rate_w carries no caller privilege of any kind");
    }

    // --- Ownerlessness -------------------------------------------------------------------------

    function test_thereIsNoAdministrativeSurface() public view {
        string[6] memory sigs_ = [
            "owner()",
            "admin()",
            "wards(address)",
            "rely(address)",
            "setRate(uint256)",
            "transferOwnership(address)"
        ];
        for (uint256 i; i < sigs_.length; ++i) {
            (bool ok_,) = address(calc).staticcall(abi.encodeWithSignature(sigs_[i], address(0)));
            assertFalse(ok_, sigs_[i]);
        }
    }

    // --- Fuzz ----------------------------------------------------------------------------------

    function testFuzz_neverRevertsOnAnyNav(uint256 nav_, uint32 dt_) public {
        // Seed a measurable window first. With fewer than MIN_INTERVALS publications every path
        // exits before the arithmetic, and the fuzz would prove nothing about the ring lookup,
        // the delta, the overflow guard or the annualisation.
        skip(7 days);
        pip.poke(NAV0 + 1e14);
        calc.rate_w();
        skip(7 days);
        pip.poke(NAV0 + 2e14);
        calc.rate_w();

        pip.poke(nav_);
        skip(SPACING + dt_);
        calc.rate_w(); // past the floor, so nav_ (saturated) records and the measurement runs over it
        skip(dt_);
        calc.rate();
        calc.rate_w();
        calc.apr();
        calc.measuredSpan();
    }

    function testFuzz_aPlausibleYieldStaysInsideTheMonetaryPolicyClamp(uint16 aprBps_) public {
        aprBps_ = uint16(bound(aprBps_, 100, 5000)); // 1% to 50% APR
        _runWeeks(8, aprBps_);

        uint256 r_ = calc.rate();
        assertGe(r_, MP_MIN_RATE, "a plausible yield must not be clamped up by the policy");
        assertLe(r_, MP_MAX_RATE, "nor clamped down by it");
    }
}
