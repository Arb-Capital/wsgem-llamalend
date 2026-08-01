// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {IWsgem}          from "./interfaces/IWsgem.sol";
import {IPip}            from "./interfaces/IPip.sol";
import {IRateCalculator} from "./interfaces/IRateCalculator.sol";

/// @title WsgemRateCalculator
/// @author Arb Capital
/// @notice Ownerless yield-rate source for a Curve `HyperbolicDynamicMP` monetary policy: reports
///         the wsgem's realised yield as a per-second rate, scaled by 1e18.
/// @dev Ownerless and immutable in the same sense as the oracle beside it: no owner, no ward, no
///      setter, no upgrade path. The only mutable state is the ring of NAV checkpoints.
///
///      MEASURED BETWEEN PUBLICATIONS, NOT ON A CLOCK. A wsgem's NAV does not accrue continuously;
///      it is republished on a cadence and is flat in between. So a checkpoint is taken when the
///      NAV *changes*, and the rate is the growth between two stored publications divided by the
///      time between them:
///
///          rate = (nav[k] / nav[k-N] - 1) / (t[k] - t[k-N])
///
///      Anchoring on publications rather than wall-clock buckets is what makes this stable. The
///      measured value is constant between publications -- it cannot sawtooth, because a partial
///      publication interval never enters the calculation. It also means a short window is safe:
///      four intervals is enough, where a clock-based window would need many more just to average
///      the cadence out.
///
///      WHY FOUR AND NOT FORTY. The underlying yield tracks a policy rate that moves in steps. A
///      long window is not conservatism, it is lag: after a rate cut it keeps reporting the old,
///      higher yield, and borrowers pay above what their collateral earns for the whole length of
///      the window. Four intervals tracks a step change within a month while still dividing
///      endpoint timing jitter by four. Systematic observation lag cancels entirely, since it
///      shifts both endpoints equally.
///
///      IF THE CADENCE CHANGES. Nothing here assumes the publication cadence survives. A slower
///      feed simply spans wider intervals. A faster one -- up to continuous per-block accrual, a
///      plausible future for this feed -- runs into `MIN_CHECKPOINT_SPACING`: checkpoints are
///      never recorded closer together than the floor, so the window degrades gracefully from
///      publication-anchored to time-anchored (a rolling `INTERVALS * MIN_CHECKPOINT_SPACING` of
///      realised yield) instead of collapsing to the last few observations. The floor also puts
///      a hard lower bound on the measurement denominator, which is what keeps a republication
///      burst -- or a burst of observations lagging one -- from reading as an absurd
///      instantaneous rate. One deployment serves both regimes; the transition needs no action.
///
///      IF PUBLICATIONS STOP. Between publications the reported rate is deliberately flat. Once
///      the feed is overdue by more than `MAX_PUBLICATION_GAP`, the denominator starts growing
///      with the wall clock, so the reported rate decays toward zero rather than being held
///      indefinitely on evidence that has stopped arriving.
///
///      HOW IT FAILS. Every failure resolves to zero rather than a revert: too few publications
///      seen, a NAV that has not risen, a zero denominator, an absurd numerator. Curve's monetary
///      policy then clamps zero up to `MIN_TARGET_RATE`, about 1% APR. Reporting zero is also the
///      safe direction -- saturating high on garbage would let anyone able to move the feed drive
///      the borrow rate to the policy's ceiling.
///
///      `rate_w` is permissionless, and safely so: a checkpoint is only ever appended when the NAV
///      differs from the newest stored one, so no caller can add a spurious entry. All a caller
///      can influence is how promptly a genuine publication is observed.
contract WsgemRateCalculator is IRateCalculator {
    // --- Constants ---------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    /// @notice Size of the checkpoint ring. Bounds `INTERVALS` at `SLOTS - 1`.
    uint256 public constant SLOTS = 8;

    /// @notice Fewest intervals that will be measured over.
    /// @dev Below this the estimate rests on too few publications to mean anything -- a single
    ///      anomalous one would set the borrow rate outright. Reporting zero instead means the
    ///      monetary policy floors until the record has substance, which costs nothing in practice:
    ///      a new market's borrow cap is zero until a Curve DAO vote lifts it, so the market is
    ///      inert through exactly this period.
    uint256 public constant MIN_INTERVALS = 2;

    /// @notice Upper bound on the gas forwarded to the feed on a read.
    /// @dev Same defence as on the oracle beside this contract: the pip sits behind an upgradeable
    ///      proxy, and this contract is called from inside every borrow, repay and liquidation, so
    ///      a hostile implementation must not be able to burn the transaction's gas or return an
    ///      enormous payload. A live read costs on the order of ten thousand gas (measured in the
    ///      fork suite); an implementation that exceeds the cap reads as paused. Lower than the
    ///      oracle's cap: this contract reads the pip raw, one hop, where the oracle's quote read
    ///      goes through the wrapper.
    uint256 public constant PIP_READ_GAS = 250_000;

    // --- Immutables --------------------------------------------------------------------------

    /// @notice The wsgem whose yield is measured.
    IWsgem public immutable WSGEM;

    /// @notice The wsgem's price feed, cached at construction (it is `immutable` on the wsgem).
    IPip public immutable PIP;

    /// @notice How many publication intervals the measurement spans.
    uint256 public immutable INTERVALS;

    /// @notice How long after the last publication the feed is considered overdue.
    /// @dev Grace, not a deadline. Inside it the reported rate is flat; past it the denominator
    ///      grows with the wall clock and the rate decays. Set it above the publication cadence
    ///      with room for a late one.
    uint256 public immutable MAX_PUBLICATION_GAP;

    /// @notice Minimum time between recorded checkpoints. Zero disables the floor.
    /// @dev The cadence bridge -- see the contract note. Inert at any publication cadence slower
    ///      than the floor; a time anchor if the feed ever accrues faster than it. Bounded below
    ///      the grace period, because a floor at or above the grace would let the rate read
    ///      overdue while a genuine publication sat deferred behind the floor.
    uint256 public immutable MIN_CHECKPOINT_SPACING;

    // --- Types -------------------------------------------------------------------------------

    /// @dev One storage slot. `uint208` holds any NAV that is not already nonsense (2.6e62 in WAD);
    ///      a larger reading is saturated rather than allowed to wrap.
    struct Checkpoint {
        uint208 nav;
        uint48  timestamp;
    }

    // --- Storage -----------------------------------------------------------------------------

    Checkpoint[SLOTS] internal _ring;

    /// @dev Ring cursor and fill count, both bounded by `SLOTS`, packed into one slot: this
    ///      contract is read inside every borrow, repay and liquidation, and together they cost
    ///      one cold SLOAD instead of two.
    uint128 internal _head;
    uint128 internal _filled;

    // --- Errors ------------------------------------------------------------------------------

    error ZeroAddress();
    error IntervalsOutOfRange();
    error PublicationGapOutOfRange();
    error SpacingOutOfRange();
    error OraclePaused();

    // --- Events ------------------------------------------------------------------------------

    /// @notice Emitted when a new publication is recorded.
    event Checkpointed(uint256 indexed nav, uint256 indexed slot);

    // --- Construction ------------------------------------------------------------------------

    /// @param wsgem_                The wsgem whose yield is measured.
    /// @param intervals_            Publication intervals to measure across. In [2, SLOTS - 1].
    /// @param maxPublicationGap_    Grace period past the last publication before the rate decays.
    /// @param minCheckpointSpacing_ Floor on the time between recorded checkpoints. Below the
    ///                              grace; zero disables it.
    constructor(
        IWsgem wsgem_,
        uint256 intervals_,
        uint256 maxPublicationGap_,
        uint256 minCheckpointSpacing_
    ) {
        if (address(wsgem_) == address(0)) revert ZeroAddress();
        if (intervals_ < MIN_INTERVALS || intervals_ > SLOTS - 1) revert IntervalsOutOfRange();
        if (maxPublicationGap_ < 1 days || maxPublicationGap_ > 90 days) {
            revert PublicationGapOutOfRange();
        }
        if (minCheckpointSpacing_ >= maxPublicationGap_) revert SpacingOutOfRange();

        address pip_ = wsgem_.pip();
        if (pip_ == address(0)) revert ZeroAddress();

        WSGEM                  = wsgem_;
        PIP                    = IPip(pip_);
        INTERVALS              = intervals_;
        MAX_PUBLICATION_GAP    = maxPublicationGap_;
        MIN_CHECKPOINT_SPACING = minCheckpointSpacing_;

        // Refuse to deploy against a paused feed: the first checkpoint would be a zero NAV, which
        // is not a measurement of anything and would sit in the ring as a zero denominator.
        uint256 spot_ = _spot();
        if (spot_ == 0) revert OraclePaused();

        _ring[0] = Checkpoint({nav: _toUint208(spot_), timestamp: uint48(block.timestamp)});
        _filled  = 1;

        emit Checkpointed(spot_, 0);
    }

    // --- Curve rate calculator ---------------------------------------------------------------

    /// @notice Realised per-second yield across the last `INTERVALS` publications, scaled by 1e18.
    /// @dev Annualise with `rate() * 365 days / 1e18`.
    function rate() external view returns (uint256) {
        return _rate();
    }

    /// @notice Same measurement as `rate()`, recording a checkpoint if the NAV has been republished.
    /// @dev Driven in normal operation by `LendController.save_rate()`, which the Controller calls
    ///      on every user operation. No keeper is required.
    function rate_w() external returns (uint256) {
        _checkpoint();
        return _rate();
    }

    // --- Views -------------------------------------------------------------------------------

    /// @notice `rate()` annualised, scaled by 1e18.
    /// @dev Saturating. Nothing on the monetary policy's path reads this, but a convenience view
    ///      that can revert is a convenience view that breaks a block explorer.
    function apr() external view returns (uint256) {
        uint256 r_ = _rate();
        unchecked {
            uint256 apr_ = r_ * 365 days;
            if (r_ != 0 && apr_ / r_ != uint256(365 days)) return type(uint256).max;
            return apr_;
        }
    }

    /// @notice The raw feed reading, or zero when the feed is paused or unreadable.
    function spotNav() external view returns (uint256) {
        return _spot();
    }

    /// @notice How many intervals are currently being measured across.
    /// @dev Ramps from 0 to `INTERVALS` as publications accumulate. Zero-rate below
    ///      `MIN_INTERVALS`.
    function intervalsMeasured() external view returns (uint256) {
        return _intervals();
    }

    /// @notice Whether enough publications have been seen for a rate to be reported at all.
    function measurable() external view returns (bool) {
        return _intervals() >= MIN_INTERVALS;
    }

    /// @notice The denominator currently in use, in seconds.
    /// @dev Equals the time between the two endpoint publications, plus any overdue time past
    ///      `MAX_PUBLICATION_GAP`. Constant between publications while the feed is on schedule.
    function measuredSpan() external view returns (uint256) {
        uint256 n_ = _intervals();
        if (n_ < MIN_INTERVALS) return 0;
        return _span(_ring[_head], _ring[_indexBack(n_)]);
    }

    /// @notice Whether the feed is past its grace period, so the reported rate is decaying.
    function overdue() external view returns (bool) {
        // The grace period is measured in days. Validator latitude over `block.timestamp` cannot
        // meaningfully move a boundary that coarse.
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp > uint256(_ring[_head].timestamp) + MAX_PUBLICATION_GAP;
    }

    /// @notice The publication at the far end of the measurement window.
    function oldestCheckpoint() external view returns (uint256 nav_, uint256 timestamp_) {
        uint256 n_ = _intervals();
        Checkpoint memory c_ = _ring[_indexBack(n_ < MIN_INTERVALS ? 0 : n_)];
        return (c_.nav, c_.timestamp);
    }

    /// @notice The most recent publication recorded.
    function newestCheckpoint() external view returns (uint256 nav_, uint256 timestamp_) {
        Checkpoint memory c_ = _ring[_head];
        return (c_.nav, c_.timestamp);
    }

    /// @notice How many publications the ring holds, up to `SLOTS`.
    function checkpointCount() external view returns (uint256) {
        return _filled;
    }

    // --- Internals ---------------------------------------------------------------------------

    /// @notice Record a checkpoint if the NAV has been republished since the last one.
    /// @dev The change test is what makes this both correct and safe to expose: an unchanged NAV is
    ///      not a publication, so repeated calls cannot pack the ring with entries that would
    ///      collapse the measurement window. A zero or unreadable feed is never recorded -- a zero
    ///      NAV in the ring would be a zero denominator waiting to be measured against.
    function _checkpoint() internal {
        uint256 spot_ = _spot();
        if (spot_ == 0) return;

        uint256 head_ = _head;
        Checkpoint memory newest_ = _ring[head_];
        if (newest_.nav == _toUint208(spot_)) return; // no publication since the last one

        // The spacing floor. A change observed inside it is deferred, not dropped: the first
        // rate_w past the floor records it, telescoped through any further changes in between.
        // Direction-blind on purpose: a fall waits like a rise, because a floor that let falls
        // through early could be packed by a down-then-up sequence into the collapsed span it
        // exists to prevent. The floor is measured in hours-to-days; validator latitude over
        // `block.timestamp` cannot meaningfully move a boundary that coarse.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - uint256(newest_.timestamp) < MIN_CHECKPOINT_SPACING) return;

        uint256 next_ = (head_ + 1) % SLOTS;
        _ring[next_]  = Checkpoint({nav: _toUint208(spot_), timestamp: uint48(block.timestamp)});
        // casting to 'uint128' is safe because next_ < SLOTS
        // forge-lint: disable-next-line(unsafe-typecast)
        _head         = uint128(next_);
        if (_filled < SLOTS) _filled += 1;

        emit Checkpointed(spot_, next_);
    }

    function _rate() internal view returns (uint256) {
        uint256 n_ = _intervals();
        if (n_ < MIN_INTERVALS) return 0;

        Checkpoint memory new_ = _ring[_head];
        Checkpoint memory old_ = _ring[_indexBack(n_)];

        if (old_.nav == 0) return 0;
        if (new_.nav <= old_.nav) return 0; // flat or falling NAV pays no yield

        uint256 elapsed_ = _span(new_, old_);
        if (elapsed_ == 0) return 0;

        // Scaling the delta first is what keeps this from overflowing. A NAV that has grown by more
        // than ~1.1e59x is not a yield measurement, it is a broken or captured feed; zero is the
        // safe reading, since saturating high would hand the borrow rate to whoever moved it.
        uint256 delta_ = new_.nav - old_.nav;
        if (delta_ > type(uint256).max / WAD) return 0;

        return ((delta_ * WAD) / old_.nav) / elapsed_;
    }

    /// @notice The measurement denominator: time between the endpoint publications, extended by any
    ///         time the feed is overdue.
    /// @dev Flat while the feed publishes on schedule, which is what keeps the reported rate from
    ///      sawtoothing between publications. Growing once it is overdue, which is what makes an
    ///      abandoned feed decay toward zero instead of holding its last reading forever.
    function _span(Checkpoint memory new_, Checkpoint memory old_) internal view returns (uint256) {
        uint256 span_ = uint256(new_.timestamp) - uint256(old_.timestamp);
        uint256 due_  = uint256(new_.timestamp) + MAX_PUBLICATION_GAP;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > due_) span_ += block.timestamp - due_;
        return span_;
    }

    /// @notice Intervals available to measure across: `INTERVALS`, or fewer early on.
    function _intervals() internal view returns (uint256) {
        uint256 available_ = _filled - 1;
        return available_ < INTERVALS ? available_ : INTERVALS;
    }

    /// @notice Ring index `n` publications back from the head.
    function _indexBack(uint256 n_) internal view returns (uint256) {
        return (_head + SLOTS - n_) % SLOTS;
    }

    /// @notice The feed reading, with an unreadable feed folded into the same zero the feed uses to
    ///         signal a pause.
    /// @dev `pip` sits behind an upgradeable proxy, so `read()` reverting is a state to absorb, not
    ///      a reason to revert in turn -- this contract is called from inside every borrow, repay
    ///      and liquidation. The call is capped at `PIP_READ_GAS` and only the first return word is
    ///      ever copied, so a gas-burning or payload-bombing implementation is absorbed the same
    ///      way rather than allowed to out-of-gas the caller.
    function _spot() internal view returns (uint256) {
        bytes memory data_ = abi.encodeCall(IPip.read, ());
        address pip_ = address(PIP);
        bool ok_;
        uint256 size_;
        uint256 nav_;
        assembly ("memory-safe") {
            ok_   := staticcall(PIP_READ_GAS, pip_, add(data_, 0x20), mload(data_), 0x00, 0x20)
            size_ := returndatasize()
            nav_  := mload(0x00)
        }
        if (!ok_ || size_ < 32) return 0;
        return nav_ > type(uint208).max ? uint256(type(uint208).max) : nav_;
    }

    /// @dev Saturating, not truncating: the branch is what makes the cast safe. A NAV past 2.6e62
    ///      in WAD is already nonsense, and saturating keeps it from wrapping to a small number,
    ///      which would read as a collapse in yield rather than as the garbage it is.
    function _toUint208(uint256 x_) internal pure returns (uint208) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x_ > type(uint208).max ? type(uint208).max : uint208(x_);
    }
}
