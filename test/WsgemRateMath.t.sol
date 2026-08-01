// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                 from "forge-std/Test.sol";
import {WsgemLlamalendOracle} from "../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../src/WsgemRateCalculator.sol";
import {IWsgem}               from "../src/interfaces/IWsgem.sol";
import {MockPip, MockGem, MockWsgem} from "./mocks/MockWsgem.sol";

/// @notice A reference implementation of both shims' arithmetic, written independently of the
///         production code so a mistake has to be made twice to go unnoticed.
/// @dev Deliberately naive: no packing, no saturation tricks, no ring buffer. Where the production
///      contracts optimise, this does the obvious thing and the differential tests below assert
///      they agree.
library RateMathReference {
    uint256 internal constant WAD = 1e18;

    /// @notice The oracle's ceiling: `cached` grown by `speed` per second over `elapsed`, with
    ///         elapsed capped and the result saturating rather than reverting.
    function ceiling(uint256 cached_, uint256 speed_, uint256 elapsed_, uint256 maxElapsed_)
        internal
        pure
        returns (uint256)
    {
        if (elapsed_ > maxElapsed_) elapsed_ = maxElapsed_;
        if (elapsed_ == 0) return cached_;

        // Compute in a wider space than the production path uses, so an overflow there shows up
        // here as a finite number rather than the same saturation.
        uint256 rate_ = speed_ * elapsed_;
        if (cached_ != 0 && rate_ != 0 && cached_ > type(uint256).max / rate_) {
            return type(uint256).max;
        }
        uint256 growth_ = (cached_ * rate_) / WAD;
        unchecked {
            uint256 sum_ = cached_ + growth_;
            if (sum_ < cached_) return type(uint256).max;
            return sum_;
        }
    }

    /// @notice The reported price: frozen on a zero read, otherwise the feed capped by the ceiling.
    function reported(uint256 spot_, uint256 cached_, uint256 ceiling_) internal pure returns (uint256) {
        if (spot_ == 0) return cached_;
        return spot_ < ceiling_ ? spot_ : ceiling_;
    }

    /// @notice The calculator's per-second rate between two publications.
    function rate(uint256 navOld_, uint256 navNew_, uint256 elapsed_) internal pure returns (uint256) {
        if (navOld_ == 0 || navNew_ <= navOld_ || elapsed_ == 0) return 0;
        uint256 delta_ = navNew_ - navOld_;
        if (delta_ > type(uint256).max / WAD) return 0;
        return ((delta_ * WAD) / navOld_) / elapsed_;
    }
}

/// @notice Hardening for the arithmetic in both shims.
/// @dev The rest of the suite tests behaviour; this tests the maths that behaviour rests on. Both
///      contracts are almost entirely arithmetic, and the oracle's ceiling in particular is the one
///      number standing between a mistaken publication and the vault -- so it is exercised here
///      against an independent reference, at its boundaries, and for the properties an attacker
///      would look for.
contract WsgemRateMathTest is Test {
    uint256 internal constant WAD   = 1e18;
    uint256 internal constant SPEED = uint256(0.0025e18) / 1 days; // the configured 0.25%/day
    uint256 internal constant NAV0  = 1e18;

    MockPip              internal pip;
    MockGem              internal gem;
    MockWsgem            internal wsgem;
    WsgemLlamalendOracle internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip    = new MockPip(NAV0);
        gem    = new MockGem(18);
        wsgem  = new MockWsgem(address(gem), address(pip), 18);
        oracle = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);
    }

    // --- The ceiling, against an independent reference ------------------------------------------

    function testFuzz_ceilingMatchesTheReference(uint128 nav_, uint32 dt_) public {
        vm.assume(nav_ > 0);
        pip.poke(nav_);
        oracle.price_w();

        // Read the checkpoint back rather than assuming it equals the poke: the ratchet is what
        // decides how much of a jump was actually accepted, which is the thing under test.
        uint256 cached_ = oracle.cachedPrice();

        skip(dt_);

        uint256 expected_ = RateMathReference.ceiling(cached_, SPEED, dt_, oracle.MAX_ELAPSED());
        assertEq(oracle.priceCeiling(), expected_);
    }

    function testFuzz_reportedPriceMatchesTheReference(uint128 nav0_, uint128 nav1_, uint32 dt_) public {
        vm.assume(nav0_ > 0);
        pip.poke(nav0_);
        oracle.price_w();
        uint256 cached_ = oracle.cachedPrice();

        pip.poke(nav1_);
        skip(dt_);

        uint256 ceiling_ = RateMathReference.ceiling(cached_, SPEED, dt_, oracle.MAX_ELAPSED());
        assertEq(oracle.price(), RateMathReference.reported(nav1_, cached_, ceiling_));
    }

    // --- Ceiling boundaries ---------------------------------------------------------------------

    function test_zeroElapsedGivesExactlyTheCachedPrice() public view {
        assertEq(oracle.priceCeiling(), oracle.cachedPrice());
    }

    function test_oneSecondOfAllowanceIsNotLostToRounding() public {
        skip(1);
        assertGt(oracle.priceCeiling(), NAV0, "a whole second must buy at least one wei at WAD scale");
    }

    function test_elapsedIsClampedExactlyAtMaxElapsed() public {
        uint256 max_ = oracle.MAX_ELAPSED();

        skip(max_);
        uint256 atCap_ = oracle.priceCeiling();

        skip(3650 days);
        assertEq(oracle.priceCeiling(), atCap_, "no allowance accrues past MAX_ELAPSED");
    }

    function test_theCeilingIsMonotoneInElapsedTime() public {
        uint256 prev_;
        for (uint256 i; i <= 8; ++i) {
            uint256 c_ = oracle.priceCeiling();
            assertGe(c_, prev_, "more time must never buy less allowance");
            prev_ = c_;
            skip(1 days);
        }
    }

    /// @dev The saturation branch. A ceiling that reverted here would propagate into every AMM read
    ///      and brick the market, so it must saturate -- and saturating is harmless, since the
    ///      value is only ever used as an upper bound on the feed.
    function test_anAbsurdCachedPriceSaturatesRatherThanReverting() public {
        // The ratchet cannot climb to a number this large, so seed it through the constructor --
        // which checkpoints the feed directly, and is the one path that can.
        pip.poke(type(uint208).max);
        WsgemLlamalendOracle o_ =
            new WsgemLlamalendOracle(IWsgem(address(wsgem)), oracle.MAX_UPSIDE_SPEED_LIMIT());

        skip(o_.MAX_ELAPSED());
        assertEq(o_.priceCeiling(), type(uint256).max, "must saturate, not revert");
        assertGt(o_.price(), 0);
        assertGt(o_.price_w(), 0);
    }

    /// @dev The storage clamp. A reading near the top of uint256 used to be the addition-overflow
    ///      case in `_ceiling`; with `_spot` saturating every quote at uint208 -- what lets the
    ///      anchor share one slot with its checkpoint -- that branch is unreachable (the sum tops
    ///      out near 7e64), and what must be pinned instead is the clamp itself: an absurd
    ///      reading saturates on the way in, wraps nothing, and the shim keeps quoting.
    function test_anAbsurdNavIsSaturatedAtTheStorageBound() public {
        pip.poke(type(uint256).max - 1e58);
        WsgemLlamalendOracle o_ = new WsgemLlamalendOracle(IWsgem(address(wsgem)), 1);

        assertEq(o_.cachedPrice(), type(uint208).max, "the anchor is clamped, not truncated");
        assertEq(o_.spotPrice(), type(uint208).max, "the raw view is clamped the same way");

        skip(1);
        assertGt(o_.price(), 0);
        assertGt(o_.price_w(), 0);
    }

    /// @dev Dust. Below roughly 58 wei a full week of allowance rounds to nothing, so the
    ///      ceiling stops growing. Documented rather than fixed: it can only be reached if the
    ///      NAV has already collapsed to 5.8e-17 of a gem, and being stuck low is the safe
    ///      direction. A genuine one-wei QUOTE is an ordinary price and anchors like any other
    ///      -- the live-zero state is carried separately, not as a reserved price value.
    function test_aDustPriceStopsRatchetingButNeverReverts() public {
        pip.poke(1);
        oracle.price_w();
        assertEq(oracle.price(), 1);
        assertFalse(oracle.quoteIsZero(), "a genuine one-wei quote is not the zero-quote state");

        skip(oracle.MAX_ELAPSED());
        assertEq(oracle.priceCeiling(), 1, "growth rounds to zero at dust");

        pip.poke(NAV0);
        assertEq(oracle.price(), 1, "stuck low -- the safe direction");
        assertGt(oracle.price_w(), 0, "and never reverts");
    }

    // --- Call frequency cannot be gamed ----------------------------------------------------------

    /// @notice Calling `price_w` more often must not buy meaningfully more allowance.
    /// @dev The ratchet is linear within a step and compounds across them, so frequent calls
    ///      approach continuous compounding while a single call is simple interest. The gap is
    ///      bounded by e^x vs 1+x -- second order, and worth pinning because "call it in a loop"
    ///      is the first thing anyone would try against a rate limit.
    function test_frequentCallsBuyAlmostNoExtraAllowance() public {
        // Two oracles from the same checkpoint. `oracle` is never written to, so it accrues one
        // step of simple growth over the day; `eager_` is written every block and compounds.
        WsgemLlamalendOracle eager_ = new WsgemLlamalendOracle(IWsgem(address(wsgem)), SPEED);

        pip.poke(type(uint128).max); // far above both, so the ceiling always binds

        for (uint256 i; i < 7200; ++i) {
            skip(12);
            eager_.price_w();
        }

        uint256 eagerPrice_ = eager_.price();
        uint256 lazyPrice_  = oracle.price();

        assertGe(eagerPrice_, lazyPrice_, "continuous compounding is the upper bound");
        assertApproxEqRel(eagerPrice_, lazyPrice_, 0.0001e18, "and the gap is under 1 bp over a day");
    }

    /// @notice Over the horizon that matters, gaming the call frequency saves about a day.
    /// @dev The claim in the docs is that a 10x publication takes ~2.5 years to propagate. That
    ///      claim has to hold against a caller hammering `price_w`, not just against a lazy market.
    function test_aTenXPublicationStillTakesYearsUnderConstantCalling() public {
        pip.poke(NAV0 * 10);

        uint256 days_;
        while (oracle.price() < NAV0 * 10 && days_ < 4000) {
            // Four calls a day rather than one, to compound as hard as the limit allows.
            for (uint256 i; i < 4; ++i) {
                skip(6 hours);
                oracle.price_w();
            }
            ++days_;
        }

        assertGe(days_, 900, "a 10x publication must still take years, however often it is polled");
        assertEq(oracle.price(), NAV0 * 10, "and must eventually arrive");
    }

    // --- The limit does not bind in ordinary operation ---------------------------------------------

    /// @notice The configured speed against the observed cadence: a weekly step must clear in hours.
    function test_theObservedWeeklyStepClearsInAboutSixAndAHalfHours() public {
        uint256 target_ = NAV0 + (NAV0 * 68) / 100_000; // +6.8 bp
        pip.poke(target_);

        skip(6 hours);
        assertLt(oracle.price(), target_, "still closing at six hours");

        skip(1 hours);
        oracle.price_w();
        assertEq(oracle.price(), target_, "cleared by seven");
    }

    /// @notice Over a year of the observed cadence, the limit costs almost nothing.
    /// @dev The cost of keeping the rate limit is quoted in the docs and in
    ///      `script/WstGBP.s.sol` as a time-averaged under-report of about 0.13 bp. Rather than
    ///      restate that claim, this walks a year of the real cadence hour by hour and measures it.
    ///      If the configured speed is ever loosened or tightened, this is what fails.
    function test_aYearOfNormalOperationCostsAboutATenthOfABasisPoint() public {
        uint256 nav_ = NAV0;
        uint256 gapSum_;
        uint256 samples_;

        for (uint256 w_; w_ < 52; ++w_) {
            nav_ = nav_ + (nav_ * 68) / 100_000; // the observed 6.8 bp step
            pip.poke(nav_);

            for (uint256 h_; h_ < 168; ++h_) {
                skip(1 hours);
                uint256 p_ = oracle.price_w();
                gapSum_ += ((nav_ - p_) * 1e18) / nav_; // relative shortfall, WAD
                ++samples_;
            }
        }

        uint256 meanGap_ = gapSum_ / samples_;
        assertLt(meanGap_, 0.00002e18, "mean under-report must stay under 0.2 bp");
        assertEq(oracle.price(), nav_, "and must be exact well before each week ends");
    }

    // --- The calculator's rate, against the reference ----------------------------------------------

    function testFuzz_rateMatchesTheReference(uint96 navOld_, uint96 delta_, uint32 elapsed_) public pure {
        uint256 navNew_ = uint256(navOld_) + uint256(delta_);
        uint256 got_    = RateMathReference.rate(navOld_, navNew_, elapsed_);

        // Recompute a second way: growth as a ratio first, then divide by time.
        if (navOld_ == 0 || navNew_ <= navOld_ || elapsed_ == 0) {
            assertEq(got_, 0);
            return;
        }
        uint256 growth_ = ((navNew_ - navOld_) * 1e18) / navOld_;
        assertEq(got_, growth_ / elapsed_);
    }

    /// @notice The rate is monotone in growth and inversely monotone in elapsed time.
    /// @dev Two properties an attacker would probe: can more time produce a higher rate (no), and
    ///      can less growth produce a higher rate (no).
    function testFuzz_rateIsMonotoneInItsInputs(uint96 navOld_, uint96 delta_, uint32 elapsed_) public pure {
        navOld_  = uint96(bound(navOld_, 1e12, type(uint96).max));
        elapsed_ = uint32(bound(elapsed_, 1, type(uint32).max - 1));

        uint256 base_ = RateMathReference.rate(navOld_, uint256(navOld_) + delta_, elapsed_);

        assertGe(
            RateMathReference.rate(navOld_, uint256(navOld_) + delta_ + 1, elapsed_),
            base_,
            "more growth cannot pay less"
        );
        assertLe(
            RateMathReference.rate(navOld_, uint256(navOld_) + delta_, uint256(elapsed_) + 1),
            base_,
            "more time cannot pay more"
        );
    }

    function test_rateHandlesTheOverflowGuardBoundary() public pure {
        uint256 justUnder_ = type(uint256).max / WAD;

        assertEq(RateMathReference.rate(1, 1 + justUnder_, 1), (justUnder_ * WAD) / 1, "at the edge");
        assertEq(RateMathReference.rate(1, 2 + justUnder_, 1), 0, "past it, zero rather than wrap");
    }

    // --- The ring index arithmetic, exhaustively ----------------------------------------------------

    /// @notice Walk many publications through the ring and confirm the window endpoints are always
    ///         exactly `INTERVALS` apart, through every wrap position.
    /// @dev An off-by-one in `_indexBack` would read a checkpoint from the wrong end of the window
    ///      and report a rate over an interval that never happened. Cheap to test exhaustively, so
    ///      it is: every head position, several times around.
    function test_theRingIndexIsCorrectAtEveryWrapPosition() public {
        for (uint256 intervals_ = 2; intervals_ <= 7; ++intervals_) {
            pip.poke(NAV0);
            WsgemRateCalculator c_ =
                new WsgemRateCalculator(IWsgem(address(wsgem)), intervals_, 10 days, 1 days);

            uint256 nav_ = NAV0;
            for (uint256 i; i < 30; ++i) {
                skip(7 days);
                nav_ += 1e14;
                pip.poke(nav_);
                c_.rate_w();

                uint256 n_ = c_.intervalsMeasured();
                if (n_ < c_.MIN_INTERVALS()) continue;

                (uint256 oldNav_, uint256 oldTime_) = c_.oldestCheckpoint();
                (uint256 newNav_, uint256 newTime_) = c_.newestCheckpoint();

                assertEq(newTime_ - oldTime_, n_ * 7 days, "window must span exactly n intervals");
                assertEq(newNav_ - oldNav_, n_ * 1e14, "and exactly n steps of growth");
            }
        }
    }

    /// @notice The measured rate is exactly what the endpoints imply, at every wrap position.
    function test_theMeasuredRateMatchesTheReferenceThroughTheRing() public {
        WsgemRateCalculator c_ =
            new WsgemRateCalculator(IWsgem(address(wsgem)), 4, 10 days, 1 days);

        uint256 nav_ = NAV0;
        for (uint256 i; i < 30; ++i) {
            skip(7 days);
            nav_ = nav_ + (nav_ * 68) / 1_000_000;
            pip.poke(nav_);
            c_.rate_w();

            if (!c_.measurable()) continue;

            (uint256 oldNav_,) = c_.oldestCheckpoint();
            (uint256 newNav_,) = c_.newestCheckpoint();
            assertEq(c_.rate(), RateMathReference.rate(oldNav_, newNav_, c_.measuredSpan()));
        }
    }

    // --- The overdue extension --------------------------------------------------------------------

    /// @notice The denominator is exactly the endpoint span inside grace, and exactly the overdue
    ///         excess beyond it.
    function testFuzz_theOverdueExtensionIsExact(uint32 overdueBy_) public {
        uint256 gap_ = 10 days;
        WsgemRateCalculator c_ = new WsgemRateCalculator(IWsgem(address(wsgem)), 2, gap_, 1 days);

        uint256 nav_ = NAV0;
        for (uint256 i; i < 2; ++i) {
            skip(7 days);
            nav_ += 1e14;
            pip.poke(nav_);
            c_.rate_w();
        }

        (, uint256 oldTime_) = c_.oldestCheckpoint();
        (, uint256 newTime_) = c_.newestCheckpoint();
        uint256 span_ = newTime_ - oldTime_;

        skip(overdueBy_);

        uint256 expected_ = span_;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > newTime_ + gap_) expected_ += block.timestamp - (newTime_ + gap_);
        assertEq(c_.measuredSpan(), expected_);
    }
}
