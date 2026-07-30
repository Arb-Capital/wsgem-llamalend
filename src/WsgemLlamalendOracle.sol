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
/// @notice Ownerless Curve Llamalend V2 price oracle for a wsgem/gem market: reports the price of
///         one wsgem in gem, scaled by 1e18.
/// @dev There is no owner, no ward, no setter and no upgrade path. Every parameter is `immutable`,
///      set once at construction. The only mutable state is the two-word rate-limit checkpoint.
///      This is deliberate: the wsgem's NAV is already a single storage slot behind a single key,
///      and the point of this shim is to stand between that and a lending market -- not to add a
///      second discretionary party on top of it.
///
///      DENOMINATION. Llamalend wants one unit of COLLATERAL priced in the BORROWED token, times
///      1e18, regardless of either token's decimals. For a wsgem collateral / gem borrowed market
///      that is exactly the wsgem's NAV, which the feed already publishes in WAD. The constructor
///      asserts both tokens are 18 decimals so the identity holds; an 18/non-18 pair would need a
///      scaling term this contract deliberately does not carry.
///
///      THE THREE HAZARDS, and what is done about each:
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
    ///      which is precisely what the rate limit exists to prevent. Seven days is comfortably
    ///      more than a wsgem's publication interval, so it never binds in ordinary operation.
    uint256 public constant MAX_ELAPSED = 7 days;

    /// @notice Hard ceiling on the constructor's speed argument: 100% per hour.
    /// @dev A cap looser than this is not a rate limit in any useful sense. It also keeps
    ///      `MAX_UPSIDE_SPEED * MAX_ELAPSED` far away from anything that could overflow.
    uint256 public constant MAX_UPSIDE_SPEED_LIMIT = WAD / 1 hours;

    // --- Immutables --------------------------------------------------------------------------

    /// @notice The wsgem this oracle prices.
    IWsgem public immutable WSGEM;

    /// @notice The gem the price is denominated in. Read from the wsgem at construction.
    address public immutable GEM;

    /// @notice The wsgem's price feed. `pip` is `immutable` on the wsgem, so caching it here is
    ///         byte-identical to routing through `wsgem.navprice()` and one call cheaper.
    IPip public immutable PIP;

    /// @notice Maximum relative increase in the reported price, per second, scaled by 1e18.
    /// @dev At 1e16/86400 (1% per day), a week of yield at 5% APR -- about 9.6 basis points --
    ///      is absorbed in roughly two hours, while a hostile 10x poke would take on the order of
    ///      a year to propagate. That asymmetry is the whole point: the limit is invisible in
    ///      normal operation and an effective stop otherwise.
    uint256 public immutable MAX_UPSIDE_SPEED;

    // --- Storage -----------------------------------------------------------------------------

    /// @notice The last price this oracle reported through `price_w`. Never zero after
    ///         construction.
    uint256 public cachedPrice;

    /// @notice When `cachedPrice` was last written.
    uint256 public cachedTimestamp;

    // --- Errors ------------------------------------------------------------------------------

    error ZeroAddress();
    error UnsupportedDecimals();
    error OraclePaused();
    error SpeedTooHigh();

    // --- Events ------------------------------------------------------------------------------

    /// @notice Emitted by `price_w` whenever the reported price moves.
    /// @param price The newly reported price, WAD gem-per-wsgem.
    /// @param spot  The raw feed reading at that moment, or zero if the feed was unreadable.
    event PriceUpdated(uint256 indexed price, uint256 indexed spot);

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

        // Refuse to deploy against a paused feed. There would be no last-good price to freeze at,
        // and `LendFactory.create` rejects a zero price anyway.
        uint256 spot_ = _spot();
        if (spot_ == 0) revert OraclePaused();

        cachedPrice     = spot_;
        cachedTimestamp = block.timestamp;

        emit PriceUpdated(spot_, spot_);
    }

    // --- Llamalend price oracle --------------------------------------------------------------

    /// @notice Price of one wsgem in gem, scaled by 1e18.
    /// @dev Never returns zero. See the contract-level note for what happens when the feed is
    ///      paused or unreadable.
    function price() external view returns (uint256) {
        return _price(_spot());
    }

    /// @notice Same value as `price()`, persisting the rate-limit checkpoint.
    /// @dev Deliberately permissionless. The checkpoint only ever moves the reported price toward
    ///      the feed, bounded by `MAX_UPSIDE_SPEED`; calling this more often lets the reported
    ///      price track the feed more closely but cannot push it past the feed, so there is
    ///      nothing to gain by sampling. Under normal operation the AMM drives it.
    function price_w() external returns (uint256) {
        uint256 spot_  = _spot();
        uint256 price_ = _price(spot_);

        // Always refresh the timestamp, including through a freeze. The rate limit measures time
        // since the last REPORTED price, and a freeze is a report of the same value -- letting
        // allowance accrue across a pause would hand the feed a free jump on the way out.
        cachedTimestamp = block.timestamp;

        if (price_ != cachedPrice) {
            cachedPrice = price_;
            emit PriceUpdated(price_, spot_);
        }

        return price_;
    }

    // --- Views -------------------------------------------------------------------------------

    /// @notice The raw feed reading, undamped. Zero when the feed is paused or unreadable.
    /// @dev For monitoring: a persistent gap between this and `price()` means the rate limit is
    ///      binding, which in ordinary operation it should not be.
    function spotPrice() external view returns (uint256) {
        return _spot();
    }

    /// @notice The highest price `price_w` could report right now.
    /// @dev Equals `cachedPrice` when no time has passed. Reported price is
    ///      `min(spot, priceCeiling())`, or `cachedPrice` when spot is zero.
    function priceCeiling() external view returns (uint256) {
        return _ceiling();
    }

    /// @notice Whether the feed is currently unreadable, so the reported price is frozen.
    function frozen() external view returns (bool) {
        return _spot() == 0;
    }

    // --- Internals ---------------------------------------------------------------------------

    /// @notice The feed reading, with an unreadable feed folded into the same zero the feed itself
    ///         uses to signal a pause.
    /// @dev `pip` sits behind an upgradeable proxy, so `read()` reverting is a real state and not
    ///      a reason for this contract to revert in turn. A short return is treated the same way.
    function _spot() internal view returns (uint256) {
        (bool ok_, bytes memory ret_) = address(PIP).staticcall(abi.encodeCall(IPip.read, ()));
        if (!ok_ || ret_.length < 32) return 0;
        return abi.decode(ret_, (uint256));
    }

    /// @notice The reported price for a given feed reading.
    /// @dev Pure with respect to the checkpoint, which is what makes `price()` and `price_w()`
    ///      agree within a call.
    function _price(uint256 spot_) internal view returns (uint256) {
        if (spot_ == 0) return cachedPrice; // frozen: last good price, never zero
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
