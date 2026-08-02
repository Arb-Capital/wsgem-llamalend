// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase}           from "forge-std/Base.sol";
import {StdUtils}             from "forge-std/StdUtils.sol";
import {WsgemLlamalendOracle} from "../../../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../../../src/WsgemRateCalculator.sol";
import {MockPip, MockWsgem}   from "../../mocks/MockWsgem.sol";

/// @notice Drives the two shims through everything the live system can do to them.
/// @dev The handler predicts every outcome, so `fail_on_revert = true` is meaningful: an
///      unpredicted revert is a genuine bug rather than the fuzzer wandering into an illegal call.
///      The shims are specified never to revert on any feed state, so every action here is
///      expected to succeed -- there is nothing to swallow, and anything that does revert should
///      fail the run.
///
///      The ghost variables record what the shims reported over the run, so the invariants can
///      assert properties that no single call can show.
contract WsgemShimHandler is CommonBase, StdUtils {
    WsgemLlamalendOracle public immutable ORACLE;
    WsgemRateCalculator public immutable CALC;
    MockPip public immutable PIP;
    MockWsgem public immutable WSGEM;

    // --- Ghosts ------------------------------------------------------------------------------

    /// @notice Lowest price the oracle ever reported. Must never be zero.
    uint256 public minReportedPrice = type(uint256).max;

    /// @notice Set if `price()` and `price_w()` ever disagreed within a call -- the one thing that
    ///         would make the market unconstructible and then mispriced.
    bool public priceWDiverged;

    /// @notice Set if the reported price ever exceeded the live feed reading.
    bool public overReported;

    /// @notice Set if the reported price ever rose faster than the configured limit allows.
    bool public rateLimitBreached;

    /// @notice Set if the calculator ever reported a non-zero rate while the NAV had not grown
    ///         across the measured window.
    bool public reportedYieldWithoutGrowth;

    /// @notice Set if the oracle's checkpoint clock ever moved backwards.
    bool public cachedTimestampRegressed;

    /// @notice Set if the rate-limit anchor changed while a live-zero episode was in progress.
    ///         The floor is reported without ever being anchored, so an episode must hold the
    ///         recovery anchor exactly where it stood when the episode began.
    bool public anchorMovedDuringLiveZero;

    uint256 internal immutable NAV0;
    uint256 internal lastPrice;
    uint256 internal lastPriceTime;
    uint256 internal lastCachedTimestamp;
    bool    internal wasLiveZero;
    uint256 internal episodeAnchor;

    constructor(
        WsgemLlamalendOracle oracle_,
        WsgemRateCalculator calc_,
        MockPip pip_,
        MockWsgem wsgem_
    ) {
        ORACLE              = oracle_;
        CALC                = calc_;
        PIP                 = pip_;
        WSGEM               = wsgem_;
        NAV0                = pip_.price();
        lastPrice           = oracle_.price();
        lastPriceTime       = block.timestamp;
        lastCachedTimestamp = oracle_.cachedTimestamp();
    }

    // --- Actions -----------------------------------------------------------------------------

    /// @notice Publish an arbitrary NAV, including a catastrophic one.
    function poke(uint256 nav_) public {
        PIP.poke(bound(nav_, 0, 1e30));
        _observe();
    }

    /// @notice Publish a NAV in the saturation regions the ordinary bound cannot reach: the
    ///         calculator's uint208 clamp and the oracle's ceiling saturation both live out here.
    function pokeExtreme(uint256 nav_) public {
        PIP.poke(bound(nav_, 1e30, type(uint256).max));
        _observe();
    }

    /// @notice Publish a NAV close to the current one -- the ordinary weekly step.
    function pokeNearby(uint256 seed_) public {
        uint256 cur_ = PIP.price();
        if (cur_ == 0) cur_ = 1e18;
        uint256 step_ = cur_ / 100;
        uint256 lo_   = cur_ - step_;
        uint256 hi_   = step_ > type(uint256).max - cur_ ? type(uint256).max : cur_ + step_;
        PIP.poke(bound(seed_, lo_, hi_));
        _observe();
    }

    /// @notice Pause the feed. Reads zero until poked again.
    function pause() public {
        PIP.poke(0);
        _observe();
    }

    /// @notice Move the wrapper's redemption spread, the full settable range included: at 100%
    ///         the quote is zero while the feed stays live, which is its own oracle state.
    function setFee(uint256 fee_) public {
        WSGEM.setFee(bound(fee_, 0, 1e18));
        _observe();
    }

    /// @notice Break the feed in one of the ways a proxy upgrade can, gas and payload bombs
    ///         included.
    function breakFeed(uint8 mode_) public {
        PIP.setMode(MockPip.Mode(bound(mode_, 0, 5)));
        _observe();
    }

    /// @notice Point the wrapper's quote at a value that no longer reads the pip -- the shape of
    ///         a broken or hostile Act proxy upgrade quoting over whatever the feed says. Zero
    ///         clears the override.
    function setQuoteOverride(uint256 quote_) public {
        WSGEM.setQuoteOverride(bound(quote_, 0, type(uint128).max));
        _observe();
    }

    /// @notice Let time pass with nobody driving the oracle: no `price_w`, no anchor movement,
    ///         no ghost checkpoint. The untouched-market scenario `MAX_ELAPSED` exists for --
    ///         which `_observe`'s own `price_w` call makes unreachable from every other action.
    function drift(uint256 dt_) public {
        vm.warp(block.timestamp + bound(dt_, 1, 30 days));
        // Only the read-only ghost: recording anything else would re-checkpoint the very state
        // this action exists to leave untouched. The production clock and the ghost's advance
        // together in `_observe`, so leaving both alone here keeps the rate-limit model exact.
        uint256 p_ = ORACLE.price();
        if (p_ < minReportedPrice) minReportedPrice = p_;
    }

    /// @notice The other cadence regime: a per-block accumulator dripping yield in sub-hour
    ///         steps -- the plausible future of the feed that `MIN_CHECKPOINT_SPACING` exists
    ///         to bridge. A drip that rounds to zero is correctly not a publication.
    function accrue(uint256 dt_, uint256 aprBps_) public {
        uint256 step_ = bound(dt_, 1, 2 hours);
        uint256 apr_  = bound(aprBps_, 1, 5000);
        vm.warp(block.timestamp + step_);

        uint256 nav_ = PIP.price();
        if (nav_ == 0 || nav_ > 1e30) nav_ = 1e18; // resume accrual from a sane NAV after chaos
        PIP.poke(nav_ + (nav_ * apr_ * step_) / (10_000 * 365 days));
        _observe();
    }

    /// @notice Advance time. Bounded well past `MAX_ELAPSED` so the elapsed-time cap is exercised.
    function warp(uint256 dt_) public {
        vm.warp(block.timestamp + bound(dt_, 1, 60 days));
        _observe();
    }

    /// @notice What the AMM does on every state-changing user operation.
    function priceW() public {
        _observe();
        ORACLE.price_w();
    }

    /// @notice What the Controller does on every user operation, via the monetary policy.
    function rateW() public {
        CALC.rate_w();

        uint256 r_ = CALC.rate();

        // The measurement runs between two stored publications, not against the live feed -- so
        // the growth being claimed is the growth between those two checkpoints. Comparing against
        // spot would be a different (and wrong) claim: a paused feed reads zero while the ring
        // still holds a real, already-published gain.
        (uint256 oldNav_,) = CALC.oldestCheckpoint();
        (uint256 newNav_,) = CALC.newestCheckpoint();
        if (r_ > 0 && newNav_ <= oldNav_) reportedYieldWithoutGrowth = true;
    }

    // --- Observation -------------------------------------------------------------------------

    /// @dev Records the properties the invariants assert. Called before every state change so the
    ///      rate-limit check compares two consecutive reported prices with a known elapsed time.
    function _observe() internal {
        // A LONG_RETURN read succeeds -- the shims take the first word -- so the over-report
        // check must run against it too, not be skipped as if the feed were dark. The bombs and
        // the short/reverting modes genuinely read as a pause. The oracle's spot is the
        // redemption quote, so the ghost compares against `burncost()`, not the raw NAV -- but
        // only while the pip itself is live: the pip, not the quote, is the pause authority, and
        // an overridden quote shining over a dark pip is a state the oracle rightly freezes
        // through rather than follows.
        MockPip.Mode m_ = PIP.mode();
        bool readable_  = m_ == MockPip.Mode.NORMAL || m_ == MockPip.Mode.LONG_RETURN;
        bool live_      = readable_ && PIP.price() != 0;
        uint256 spot_   = live_ ? WSGEM.burncost() : 0;
        uint256 p_      = ORACLE.price();

        if (p_ < minReportedPrice) minReportedPrice = p_;
        if (spot_ != 0 && p_ > spot_) overReported = true;

        // The factory's check, run continuously rather than once at creation.
        if (ORACLE.price_w() != p_) priceWDiverged = true;

        // The write above is the state change the checkpoint ghosts watch.
        uint256 ts_ = ORACLE.cachedTimestamp();
        if (ts_ < lastCachedTimestamp) cachedTimestampRegressed = true;
        lastCachedTimestamp = ts_;

        // A live-zero episode must hold the recovery anchor exactly where it stood on entry.
        bool liveZero_ = ORACLE.liveZeroReported();
        if (liveZero_) {
            uint256 anchor_ = ORACLE.cachedPrice();
            if (!wasLiveZero) episodeAnchor = anchor_;
            else if (anchor_ != episodeAnchor) anchorMovedDuringLiveZero = true;
        }
        wasLiveZero = liveZero_;

        uint256 elapsed_ = block.timestamp - lastPriceTime;
        if (elapsed_ > ORACLE.MAX_ELAPSED()) elapsed_ = ORACLE.MAX_ELAPSED();

        if (p_ > lastPrice) {
            // Recomputed with the production contract's own guard structure: once the allowance
            // arithmetic saturates, any price is admissible and the check has nothing to say --
            // the dedicated saturation tests pin that region. Everything below saturation is
            // checked exactly.
            uint256 rate_ = ORACLE.MAX_UPSIDE_SPEED() * elapsed_;
            bool saturated_;
            uint256 growth_;
            if (rate_ != 0 && lastPrice > type(uint256).max / rate_) {
                saturated_ = true;
            } else {
                growth_ = (lastPrice * rate_) / 1e18;
                if (growth_ > type(uint256).max - lastPrice) saturated_ = true;
            }
            if (!saturated_ && p_ > lastPrice + growth_) rateLimitBreached = true;
        }

        // Mirror the production anchor rule: the one-wei live-zero floor is never a base for
        // the rate limit, so the ghost only advances its anchor on a real quote (spot_ is zero
        // during both a pause and a zero quote). Recovery from a 100% spread is the upside
        // limit's sole, documented exception -- it returns to the held anchor's ceiling, so
        // measuring against the anchor is the restated invariant, not a hole in it.
        if (spot_ > 0) lastPrice = ORACLE.price();
        lastPriceTime = block.timestamp;
    }
}
