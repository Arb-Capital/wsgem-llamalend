// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase}           from "forge-std/Base.sol";
import {StdUtils}             from "forge-std/StdUtils.sol";
import {WsgemLlamalendOracle} from "../../../src/WsgemLlamalendOracle.sol";
import {WsgemRateCalculator}  from "../../../src/WsgemRateCalculator.sol";
import {MockPip}              from "../../mocks/MockWsgem.sol";

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

    // --- Ghosts ------------------------------------------------------------------------------

    /// @notice Lowest price the oracle ever reported. Must never be zero.
    uint256 public minReportedPrice = type(uint256).max;

    /// @notice Highest rate the calculator ever reported.
    uint256 public maxReportedRate;

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

    uint256 internal immutable NAV0;
    uint256 internal lastPrice;
    uint256 internal lastPriceTime;

    constructor(WsgemLlamalendOracle oracle_, WsgemRateCalculator calc_, MockPip pip_) {
        ORACLE        = oracle_;
        CALC          = calc_;
        PIP           = pip_;
        NAV0          = pip_.price();
        lastPrice     = oracle_.price();
        lastPriceTime = block.timestamp;
    }

    // --- Actions -----------------------------------------------------------------------------

    /// @notice Publish an arbitrary NAV, including a catastrophic one.
    function poke(uint256 nav_) public {
        PIP.poke(bound(nav_, 0, 1e30));
        _observe();
    }

    /// @notice Publish a NAV close to the current one -- the ordinary weekly step.
    function pokeNearby(uint256 seed_) public {
        uint256 cur_ = PIP.price();
        if (cur_ == 0) cur_ = 1e18;
        uint256 lo_  = cur_ - cur_ / 100;
        uint256 hi_  = cur_ + cur_ / 100;
        PIP.poke(bound(seed_, lo_, hi_));
        _observe();
    }

    /// @notice Pause the feed. Reads zero until poked again.
    function pause() public {
        PIP.poke(0);
        _observe();
    }

    /// @notice Break the feed in one of the ways a proxy upgrade can.
    function breakFeed(uint8 mode_) public {
        PIP.setMode(MockPip.Mode(bound(mode_, 0, 3)));
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
        if (r_ > maxReportedRate) maxReportedRate = r_;

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
        uint256 spot_ = PIP.mode() == MockPip.Mode.NORMAL ? PIP.price() : 0;
        uint256 p_    = ORACLE.price();

        if (p_ < minReportedPrice) minReportedPrice = p_;
        if (spot_ != 0 && p_ > spot_) overReported = true;

        // The factory's check, run continuously rather than once at creation.
        if (ORACLE.price_w() != p_) priceWDiverged = true;

        uint256 elapsed_ = block.timestamp - lastPriceTime;
        if (elapsed_ > ORACLE.MAX_ELAPSED()) elapsed_ = ORACLE.MAX_ELAPSED();

        if (p_ > lastPrice) {
            uint256 allowed_ = lastPrice + (lastPrice * ORACLE.MAX_UPSIDE_SPEED() * elapsed_) / 1e18;
            if (p_ > allowed_) rateLimitBreached = true;
        }

        lastPrice     = ORACLE.price();
        lastPriceTime = block.timestamp;
    }
}
