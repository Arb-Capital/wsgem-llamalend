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
    uint256 internal constant NAV0      = 1e18;

    /// @dev The observed cadence: ~6.8 bp per week, about 3.54% APR.
    uint256 internal constant STEP_BPS = 68; // in hundredths of a bp, i.e. 6.8bp

    /// @dev Curve's HyperbolicDynamicMP clamps whatever this contract reports into this range, so
    ///      a value outside it is never what the market actually charges.
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
        calc  = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP);
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
        assertEq(calc.checkpointCount(), 1);
    }

    function test_constructorRejectsAPausedFeed() public {
        pip.poke(0);
        vm.expectRevert(WsgemRateCalculator.OraclePaused.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP);
    }

    function test_constructorRejectsIntervalsOutOfRange() public {
        uint256 tooFew_  = calc.MIN_INTERVALS() - 1;
        uint256 tooMany_ = calc.SLOTS();

        vm.expectRevert(WsgemRateCalculator.IntervalsOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), tooFew_, GAP);

        vm.expectRevert(WsgemRateCalculator.IntervalsOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), tooMany_, GAP);
    }

    function test_constructorRejectsAGapOutOfRange() public {
        vm.expectRevert(WsgemRateCalculator.PublicationGapOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, 1 days - 1);

        vm.expectRevert(WsgemRateCalculator.PublicationGapOutOfRange.selector);
        new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, 90 days + 1);
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
        WsgemRateCalculator lagged_ = new WsgemRateCalculator(IWsgem(address(wsgem)), INTERVALS, GAP);
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
        assertEq(calc.apr(), calc.rate() * 365 days);
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
        pip.poke(nav_);
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
