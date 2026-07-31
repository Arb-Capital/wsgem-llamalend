// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {IWsgem}       from "./interfaces/IWsgem.sol";
import {IPip}         from "./interfaces/IPip.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title WsgemLlamalendOracle
/// @author Arb Capital
/// @notice Ownerless Curve Llamalend V2 price oracle for a wsgem/gem market: reports the
///         redemption price of one wsgem in gem -- the wrapper's `burncost()` -- scaled by 1e18.
/// @dev There is no owner, no ward, no setter and no upgrade path. Every parameter is `immutable`,
///      set once at construction. The only mutable state is three words: the rate-limit anchor,
///      its checkpoint time, and the live-zero flag.
///      This is deliberate: the wsgem's NAV is already a single storage slot behind a single key,
///      and the point of this shim is to stand between that and a lending market -- not to add a
///      second discretionary party on top of it.
///
///      DENOMINATION. Llamalend wants one unit of COLLATERAL priced in the BORROWED token, times
///      1e18, regardless of either token's decimals. For a wsgem collateral / gem borrowed market
///      that is the wsgem's redemption quote (`burncost`): the NAV net of the wrapper's
///      redemption spread, published in WAD, and the price at which an exit is actually
///      executable -- the market's floor. Collateral is therefore never valued above what
///      redemption pays for it, with one wei-sized exception: a live feed quoting exactly zero
///      is reported as one wei, because zero must never reach Llamalend (hazard 4 below).
///      The quote is read live on every call, so a change to the
///      wrapper's spread flows through as an ordinary price move: a spread cut is an upward move
///      and rate-limited like any other, a spread increase is a downward move and passes through
///      immediately, which is correct because the floor genuinely dropped. The constructor
///      asserts both tokens are 18 decimals so the identity holds; an 18/non-18 pair would need a
///      scaling term this contract deliberately does not carry.
///
///      THE FOUR HAZARDS, and what is done about each:
///
///      1. `price()` and `price_w()` must agree. `LendFactory.create` reads `price()` into a local
///         and asserts `price_w()` returns the same number; the AMM then uses the view on read
///         paths and the write on state-changing ones. Both functions here run the SAME pure
///         computation over the SAME checkpoint, and only `price_w` persists afterwards, so they
///         agree by construction rather than by timing.
///
///      2. A paused feed reads zero. Zero must never reach Llamalend: the factory rejects it at
///         creation, and an AMM that sees a zero mid-market prices every position to nothing. A
///         zero read -- or a reverting one, which is the same failure with a different shape after
///         a bad proxy upgrade -- freezes the reported price at the last good value instead.
///         Freezing keeps repayment and liquidation working through a pause, which is the failure
///         mode that does least damage. Note there is no staleness bound: this NAV is published on
///         a weekly cadence, so a six-day-old price is normal and any age check meaningful enough
///         to catch abandonment would also fire in ordinary operation.
///
///      3. A single poke can move the NAV arbitrarily far. Upward moves are therefore rate-limited
///         to `MAX_UPSIDE_SPEED` per second, relative, measured from the last reported price;
///         downward moves pass through immediately, because under-valuing collateral is the safe
///         direction and hiding a genuine loss behind a stale high price is not.
///
///      4. A live feed can quote zero. The wrapper's redemption spread is settable to 100%, which
///         makes `burncost()` zero while the NAV stays live. That is not a pause -- the floor is
///         genuinely nothing -- so it is not frozen over: freezing would keep borrowing open
///         against collateral that redemption values at nothing. The reported price drops to one
///         wei instead (the smallest value Llamalend accepts), carried as a distinct STATE
///         rather than a reserved price value, so a genuine one-wei quote stays an ordinary
///         price. The floor is never anchored, and recovery from it is the upside limit's SOLE
///         exception: the reported price may return to the held anchor's ceiling in one block,
///         because the round trip through a failure state is not a price increase -- the
///         admissible maximum never rose above what the anchor's own ceiling allows. Entering
///         and leaving the state emit `QuoteZeroed`/`QuoteRestored`; `quoteIsZero()`
///         distinguishes it from `frozen()`. Down, pause and zero are all failure states for
///         this feed -- in normal operation the NAV only rises.
///
///      ON THE CHOICE OF RATE LIMIT. Curve's own `price_oracles/v2/ERC4626EMAWrapper.vy` smooths
///      the upside with an exponential moving average. This contract uses the linear speed cap
///      from Curve's earlier `price_oracles/OracleVaultWrapper.vy` instead, for two reasons
///      specific to a wsgem: the NAV steps once a week rather than accruing continuously, so what
///      is wanted is a stated bound ("at most X per day") rather than an asymptote; and the cap is
///      exact integer arithmetic with no transcendental approximation to audit. The behaviour
///      contract -- dampen up, pass down, never report zero -- is the same either way.
contract WsgemLlamalendOracle is IPriceOracle {
    // --- Constants ---------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    /// @notice Upper bound on the elapsed time credited to the rate limit in one step.
    /// @dev Without this, a market left untouched for months would accumulate enough allowance for
    ///      the next `price_w` to jump the reported price arbitrarily far in a single block --
    ///      which is precisely what the rate limit exists to prevent. Seven days covers a wsgem's
    ///      publication interval, so it binds only when nothing has driven `price_w` for a full
    ///      publication cycle -- and then in the safe direction, crediting less allowance.
    uint256 public constant MAX_ELAPSED = 7 days;

    /// @notice Hard ceiling on the constructor's speed argument: 100% per hour.
    /// @dev A cap looser than this is not a rate limit in any useful sense. It also keeps
    ///      `MAX_UPSIDE_SPEED * MAX_ELAPSED` far away from anything that could overflow.
    uint256 public constant MAX_UPSIDE_SPEED_LIMIT = WAD / 1 hours;

    /// @notice Upper bound on the gas forwarded to the feed on each of the two reads.
    /// @dev The pip sits behind an upgradeable proxy, so a hostile or broken implementation could
    ///      otherwise burn the transaction's whole gas allowance -- the one way `price()` could
    ///      still fail after a plain revert has been folded into a freeze. A live read costs on
    ///      the order of ten thousand gas (measured in the fork suite), so this is more than an
    ///      order of magnitude of headroom for a legitimate proxy upgrade; an implementation that
    ///      exceeds it reads as paused, which is the freeze path and alarmed by `frozen()`.
    uint256 public constant PIP_READ_GAS = 250_000;

    /// @notice What a live feed with a zero redemption quote is reported as: one wei.
    /// @dev The wrapper's spread is settable to 100%, which makes `burncost()` zero while the NAV
    ///      stays live. That is not a pause -- the floor is genuinely nothing -- but zero must
    ///      never reach Llamalend, so the reported price is the smallest value it accepts. A
    ///      report in this state is never anchored; see `price_w`. A GENUINE one-wei quote is a
    ///      different thing entirely and is treated as any other price.
    uint256 internal constant LIVE_ZERO_PRICE = 1;

    // --- Types -------------------------------------------------------------------------------

    /// @dev What a read of the feed resolved to. `PAUSED` covers a zero NAV and every unreadable
    ///      shape; `LIVE_ZERO` is a live feed whose redemption quote is zero; `QUOTE` carries a
    ///      real price, one wei included.
    enum Spot {
        PAUSED,
        LIVE_ZERO,
        QUOTE
    }

    // --- Immutables --------------------------------------------------------------------------

    /// @notice The wsgem this oracle prices.
    IWsgem public immutable WSGEM;

    /// @notice The gem the price is denominated in. Read from the wsgem at construction.
    address public immutable GEM;

    /// @notice The wsgem's price feed, cached at construction.
    /// @dev The pause signal is read from this feed directly; the price itself comes from
    ///      `WSGEM.burncost()`, which reads the same feed and nets off the spread. The cached
    ///      address also lets a deploy script and an operator confirm the wiring without
    ///      trusting this contract's word for it.
    IPip public immutable PIP;

    /// @notice Maximum relative increase in the reported price, per second, scaled by 1e18.
    /// @dev At 0.0025e18/86400 (0.25% per day, the configured wstGBP value), a week of yield at
    ///      3.5% APR -- about 6.8 basis points -- is absorbed in roughly six and a half hours,
    ///      while a hostile 10x poke would take about two and a half years to propagate. That
    ///      asymmetry is the whole point: the limit is invisible in normal operation and an
    ///      effective stop otherwise.
    uint256 public immutable MAX_UPSIDE_SPEED;

    // --- Storage -----------------------------------------------------------------------------

    /// @notice The rate-limit anchor: the last QUOTE-state price `price_w` persisted. Never zero
    ///         after construction. During a live-zero episode the report is one wei while this
    ///         holds the recovery anchor, so it is not always the last reported price.
    uint256 public cachedPrice;

    /// @notice When the checkpoint was last touched. Refreshed by every `price_w`, freezes and
    ///         live-zero reports included, so no upside allowance accrues through either.
    uint256 public cachedTimestamp;

    /// @notice Whether the last `price_w` report was the one-wei live-zero floor.
    /// @dev What lets a subsequent pause hold the floor rather than snapping back to the anchor,
    ///      and what gates the `QuoteZeroed`/`QuoteRestored` transition events.
    bool public liveZeroReported;

    // --- Errors ------------------------------------------------------------------------------

    error ZeroAddress();
    error UnsupportedDecimals();
    error OraclePaused();
    error QuoteIsZero();
    error SpeedTooHigh();

    // --- Events ------------------------------------------------------------------------------

    /// @notice Emitted by `price_w` whenever the anchored price moves.
    /// @param price The newly reported price, WAD gem-per-wsgem.
    /// @param spot  The raw redemption quote at that moment.
    event PriceUpdated(uint256 indexed price, uint256 indexed spot);

    /// @notice Emitted by `price_w` when the report enters the one-wei live-zero floor.
    /// @param anchor The rate-limit anchor being held for recovery.
    event QuoteZeroed(uint256 indexed anchor);

    /// @notice Emitted by `price_w` when the report leaves the floor.
    /// @param price The price reported on the way out.
    event QuoteRestored(uint256 indexed price);

    // --- Construction ------------------------------------------------------------------------

    /// @param wsgem_          The wsgem to price. Must be 18 decimals, over an 18-decimal gem.
    /// @param maxUpsideSpeed_ Maximum relative price increase per second, WAD-scaled.
    constructor(IWsgem wsgem_, uint256 maxUpsideSpeed_) {
        if (address(wsgem_) == address(0)) revert ZeroAddress();
        if (maxUpsideSpeed_ == 0 || maxUpsideSpeed_ > MAX_UPSIDE_SPEED_LIMIT) revert SpeedTooHigh();

        address gem_ = wsgem_.gem();
        address pip_ = wsgem_.pip();
        if (gem_ == address(0) || pip_ == address(0)) revert ZeroAddress();

        // The WAD identity between "NAV" and "collateral price in borrowed-token terms" only holds
        // for an 18/18 pair. Refuse anything else rather than silently mis-scaling a market.
        if (wsgem_.decimals() != 18 || IDecimals(gem_).decimals() != 18) revert UnsupportedDecimals();

        WSGEM            = wsgem_;
        GEM              = gem_;
        PIP              = IPip(pip_);
        MAX_UPSIDE_SPEED = maxUpsideSpeed_;

        // Refuse to deploy against a paused feed -- there would be no last-good price to freeze
        // at -- or against a zero redemption quote, which is not a price to anchor a market on.
        (Spot state_, uint256 spot_) = _spot();
        if (state_ == Spot.PAUSED) revert OraclePaused();
        if (state_ == Spot.LIVE_ZERO) revert QuoteIsZero();

        cachedPrice     = spot_;
        cachedTimestamp = block.timestamp;

        emit PriceUpdated(spot_, spot_);
    }

    // --- Llamalend price oracle --------------------------------------------------------------

    /// @notice Price of one wsgem in gem, scaled by 1e18.
    /// @dev Never returns zero. See the contract-level note for what happens when the feed is
    ///      paused or unreadable, and when it quotes zero.
    function price() external view returns (uint256) {
        (Spot state_, uint256 spot_) = _spot();
        return _price(state_, spot_);
    }

    /// @notice Same value as `price()`, persisting the rate-limit checkpoint.
    /// @dev Deliberately permissionless. The checkpoint only ever moves the reported price toward
    ///      the feed, bounded by `MAX_UPSIDE_SPEED`; calling this more often lets the reported
    ///      price track the feed more closely but cannot push it past the feed, so there is
    ///      nothing to gain by sampling. Under normal operation the AMM drives it.
    function price_w() external returns (uint256) {
        (Spot state_, uint256 spot_) = _spot();
        uint256 price_ = _price(state_, spot_);

        // Always refresh the timestamp, including through a freeze. The rate limit measures time
        // since the last REPORTED price, and a freeze is a report of the same value -- letting
        // allowance accrue across a pause would hand the feed a free jump on the way out.
        cachedTimestamp = block.timestamp;

        if (state_ == Spot.LIVE_ZERO) {
            // The floor is reported but never anchored: it is a failure state, not a price to
            // ratchet from. Keeping the last real anchor is what lets a restored quote return
            // -- downward at full speed, upward bounded by the anchor's own ceiling -- rather
            // than ratcheting up from one wei. The transition is evented once, not per call.
            if (!liveZeroReported) {
                liveZeroReported = true;
                emit QuoteZeroed(cachedPrice);
            }
        } else if (state_ == Spot.QUOTE) {
            if (liveZeroReported) {
                liveZeroReported = false;
                emit QuoteRestored(price_);
            }
            if (price_ != cachedPrice) {
                cachedPrice = price_;
                emit PriceUpdated(price_, spot_);
            }
        }
        // PAUSED mutates nothing beyond the timestamp: a freeze preserves the last report,
        // the live-zero flag included.

        return price_;
    }

    // --- Views -------------------------------------------------------------------------------

    /// @notice The wrapper's live redemption quote, undamped. Zero when the feed is paused or
    ///         unreadable AND when the live quote is genuinely zero -- `frozen()` and
    ///         `quoteIsZero()` tell the two apart.
    /// @dev For monitoring: a persistent `price() < spotPrice()` means the rate limit is
    ///      binding, which in ordinary operation it should not be. That ordering is the exact
    ///      signal -- both failure states read zero here with the price above it.
    function spotPrice() external view returns (uint256) {
        (Spot state_, uint256 spot_) = _spot();
        return state_ == Spot.QUOTE ? spot_ : 0;
    }

    /// @notice The highest price `price_w` could report right now.
    /// @dev Equals `cachedPrice` when no time has passed. In the QUOTE state the reported price
    ///      is `min(spot, priceCeiling())`; a pause holds the last report and a live-zero quote
    ///      reports one wei, neither of which this ceiling applies to.
    function priceCeiling() external view returns (uint256) {
        return _ceiling();
    }

    /// @notice Whether the feed is currently paused or unreadable, so the reported price is
    ///         frozen at the last report.
    function frozen() external view returns (bool) {
        (Spot state_,) = _spot();
        return state_ == Spot.PAUSED;
    }

    /// @notice Whether the feed is live but the redemption quote is zero -- a 100% spread. The
    ///         reported price is one wei and is not being anchored.
    function quoteIsZero() external view returns (bool) {
        (Spot state_,) = _spot();
        return state_ == Spot.LIVE_ZERO;
    }

    // --- Internals ---------------------------------------------------------------------------

    /// @notice What the feed currently resolves to, with the quote alongside when there is one.
    /// @dev The NAV is the pause signal -- the feed publishes zero to pause, and an unreadable
    ///      feed is the same state with a different shape. Reading it separately from the quote
    ///      is what distinguishes "the feed is dark, hold the last report" from "the feed is
    ///      live and the floor is genuinely nothing", which are different failures with
    ///      different correct responses. A genuine one-wei quote is a QUOTE like any other; the
    ///      state, not a reserved price value, is what carries the distinction.
    function _spot() internal view returns (Spot state_, uint256 quote_) {
        (bool okNav_, uint256 nav_) = _readWord(address(PIP), abi.encodeCall(IPip.read, ()));
        if (!okNav_ || nav_ == 0) return (Spot.PAUSED, 0);

        bool okQuote_;
        (okQuote_, quote_) = _readWord(address(WSGEM), abi.encodeCall(IWsgem.burncost, ()));
        if (!okQuote_) return (Spot.PAUSED, 0);

        if (quote_ == 0) return (Spot.LIVE_ZERO, 0);
        return (Spot.QUOTE, quote_);
    }

    /// @dev Gas-capped, one-word staticcall: a revert, a short return, a gas burn or an
    ///      oversized payload all come back as `(false, 0)` rather than propagating. Both feed
    ///      reads route through here.
    function _readWord(address target_, bytes memory data_)
        internal
        view
        returns (bool ok_, uint256 word_)
    {
        uint256 size_;
        assembly ("memory-safe") {
            ok_   := staticcall(PIP_READ_GAS, target_, add(data_, 0x20), mload(data_), 0x00, 0x20)
            size_ := returndatasize()
            word_ := mload(0x00)
        }
        if (!ok_ || size_ < 32) return (false, 0);
        return (ok_, word_);
    }

    /// @notice The reported price for a given feed reading.
    /// @dev Pure with respect to the checkpoint, which is what makes `price()` and `price_w()`
    ///      agree within a call. A freeze holds the last REPORT -- the one-wei floor included,
    ///      when that is what was last reported -- not the last anchor.
    function _price(Spot state_, uint256 spot_) internal view returns (uint256) {
        if (state_ == Spot.PAUSED) {
            return liveZeroReported ? LIVE_ZERO_PRICE : cachedPrice; // frozen: never zero
        }
        if (state_ == Spot.LIVE_ZERO) return LIVE_ZERO_PRICE;

        uint256 ceiling_ = _ceiling();
        return spot_ < ceiling_ ? spot_ : ceiling_;
    }

    /// @notice `cachedPrice` grown by `MAX_UPSIDE_SPEED` over the elapsed time, capped.
    /// @dev Saturating rather than reverting on overflow. A revert here would propagate into every
    ///      AMM read and brick the market -- and saturation is harmless, because the result is only
    ///      ever used as an upper bound on the feed reading.
    function _ceiling() internal view returns (uint256) {
        uint256 cached_  = cachedPrice;
        uint256 elapsed_ = block.timestamp - cachedTimestamp;
        if (elapsed_ > MAX_ELAPSED) elapsed_ = MAX_ELAPSED;
        if (elapsed_ == 0) return cached_;

        uint256 growth_;
        unchecked {
            uint256 rate_ = MAX_UPSIDE_SPEED * elapsed_; // bounded by 1e18/3600 * 7 days
            growth_ = cached_ * rate_;
            if (growth_ / rate_ != cached_) return type(uint256).max;
            growth_ /= WAD;
            uint256 sum_ = cached_ + growth_;
            if (sum_ < cached_) return type(uint256).max;
            return sum_;
        }
    }
}
