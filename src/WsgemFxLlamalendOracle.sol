// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {IWsgem}                 from "./interfaces/IWsgem.sol";
import {IPip}                   from "./interfaces/IPip.sol";
import {IPriceOracle}           from "./interfaces/IPriceOracle.sol";
import {IDecimals}              from "./interfaces/IDecimals.sol";
import {IChainlinkAggregator}   from "./interfaces/IChainlinkAggregator.sol";
import {IStablePriceAggregator} from "./interfaces/IStablePriceAggregator.sol";

/// @title WsgemFxLlamalendOracle
/// @author Arb Capital
/// @notice Ownerless Curve Llamalend V2 price oracle for a wsgem collateral / foreign-stablecoin
///         borrowed market: the wrapper's redemption quote, converted across two currencies.
/// @dev The sibling of `WsgemLlamalendOracle`, for the case that contract deliberately refuses.
///      There, the borrowed token IS the wsgem's gem, so `burncost()` -- the wrapper's WAD
///      redemption quote -- already IS "one unit of collateral priced in the borrowed token, times
///      1e18", and the shim carries no scaling term at all. Here the borrowed token is a different
///      currency, the identity breaks, and the missing term is a foreign-exchange rate:
///
///          price = burncost (gem per wsgem)  x  GEM_QUOTE / BORROWED_QUOTE
///
///      with both quotes taken in the same unit of account. For wstGBP against crvUSD that reads:
///      tGBP per wstGBP, times GBP/USD, divided by crvUSD/USD.
///
///      Everything else is inherited from the sibling by deliberate repetition rather than by
///      abstraction -- read the two side by side. Same ownerlessness (no owner, no ward, no setter,
///      no upgrade path, every parameter `immutable`), same gas-capped reads, same four hazards.
///      What follows is only what is genuinely different.
///
///      WHERE THE RATE LIMIT BINDS. On the NAV leg, and nowhere else. `MAX_UPSIDE_SPEED` exists to
///      blunt a mistaken or hostile publication of an ADMINISTERED value -- a decimals slip in
///      whatever assembles the NAV off-chain. A foreign-exchange rate is not administered; it is
///      traded, two-sided, and moves a percent on an ordinary day. Throttling it would not guard
///      anything: it would systematically under-report collateral through every rally in the
///      collateral's currency and soft-liquidate healthy borrowers for the privilege. So the limit
///      is applied to the quote BEFORE conversion, and the conversion passes through untouched.
///      The stored anchor is therefore a quote, not a price -- which is why this contract needs a
///      second storage word where the sibling needs one.
///
///      THE TWO NEW FAILURE CAUSES, and what is done about each:
///
///      5. The foreign-exchange feed can halt or go mad. It is a Chainlink push feed: it carries a
///         publication time, so unlike the wsgem's `pip` it can be age-bounded, and it is bounded
///         here at `MAX_FX_AGE`. A stale, reverting, non-positive, absurd or FUTURE-STAMPED answer
///         reads as `FX_DOWN`, which freezes the reported price at its last good value -- the same
///         response hazard 2 gives a dark `pip`, for the same reason: freezing keeps repayment and
///         liquidation working, and every other answer is worse. `fxFrozen()` distinguishes it
///         from a dark `pip`, and the transition is evented.
///
///         The future stamp deserves its own mention because the obvious reading of it is the
///         dangerous one. A round stamped ahead of the chain is not "extra fresh"; it is malformed,
///         and crediting it as current would suspend the age bound for as long as the stamp stayed
///         ahead -- disabling this leg's one defence in precisely the state where something has
///         already gone wrong.
///
///      6. The borrowed token's quote is a governance dependency. Curve's crvUSD aggregator is not
///         a proxy and cannot go stale, but its admin -- the Curve DAO agent, the same one that
///         admins the LendFactory -- chooses the pools its average is taken over. This contract
///         cannot police that and does not pretend to: a zero or unreadable answer freezes, an
///         absurd one freezes, and anything in between is taken at face value. That is a real
///         widening of this repo's "nothing to trust" story and is documented as such in
///         docs/02-oracle-shim.md rather than papered over here.
///
///      WHAT IS NOT HEDGED. The gem is assumed to hold its peg to the currency the foreign-exchange
///      feed prices. For wstGBP that is tGBP against GBP, and there is no tGBP/USD feed to check it
///      with; a tGBP depeg would move this market's collateral price by exactly the depeg, in the
///      wrong direction, and nothing here would notice. See docs/04-parameters.md.
contract WsgemFxLlamalendOracle is IPriceOracle {
    // --- Constants ---------------------------------------------------------------------------

    uint256 internal constant WAD = 1e18;

    /// @notice Upper bound on the elapsed time credited to the rate limit in one step.
    /// @dev As the sibling. Seven days covers a wsgem's publication interval, so it binds only when
    ///      nothing has driven `price_w` for a full publication cycle -- and then in the safe
    ///      direction, crediting less allowance.
    uint256 public constant MAX_ELAPSED = 7 days;

    /// @notice Hard ceiling on the constructor's speed argument: 100% per hour.
    uint256 public constant MAX_UPSIDE_SPEED_LIMIT = WAD / 1 hours;

    /// @notice Bounds on the constructor's foreign-exchange staleness argument.
    /// @dev The floor keeps a deployment from configuring a bound tighter than any real feed's
    ///      heartbeat, which would freeze the market in ordinary operation. The ceiling keeps
    ///      "bounded" meaningful: past a week, an age check catches nothing a human would not have
    ///      caught first.
    uint256 public constant MIN_FX_AGE_LIMIT = 1 hours;
    uint256 public constant MAX_FX_AGE_LIMIT = 7 days;

    /// @notice Upper bound on the gas forwarded to the wsgem and its feed on each read.
    /// @dev As the sibling: the pip sits behind an upgradeable proxy, and the quote is a three-hop
    ///      read costing on the order of twenty-five thousand gas live.
    uint256 public constant PIP_READ_GAS = 300_000;

    /// @notice Upper bound on the gas forwarded to the foreign-exchange feed.
    /// @dev A Chainlink consumer holds an `EACAggregatorProxy`, which forwards to whichever
    ///      aggregator is current -- two hops, on the order of thirty thousand gas cold. The cap is
    ///      an order of magnitude above that, so a phase change cannot brick this oracle while a
    ///      pathological implementation still reads as a halted feed, which is the freeze path.
    uint256 public constant FX_FEED_READ_GAS = 300_000;

    /// @notice Upper bound on the gas forwarded to a Curve-style borrowed-token aggregator.
    /// @dev Much larger than the other two, and honestly so: Curve's crvUSD aggregator walks every
    ///      pool it averages over and cost 116,892 gas cold when measured on mainnet. Its admin can
    ///      add pairs, so the cap has to leave room for that -- roughly eight times the measured
    ///      cost. A cap this loose is a backstop against an unbounded loop, not a meaningful gas
    ///      budget, and on that path the read is the dominant cost of every price this contract
    ///      reports. The Chainlink-shaped borrowed leg uses `FX_FEED_READ_GAS` instead and costs
    ///      an order of magnitude less.
    uint256 public constant QUOTE_AGGREGATOR_READ_GAS = 1_000_000;

    /// @notice What a live feed with a zero redemption quote is reported as: one wei.
    /// @dev Also the floor on a composed price. Conversion is a multiplication and a division, and
    ///      a small enough quote against a large enough divisor rounds to zero without either feed
    ///      having failed. Zero must never reach Llamalend, so it is floored here; a genuine
    ///      one-wei price is a different thing entirely and is treated as any other price.
    uint256 internal constant LIVE_ZERO_PRICE = 1;

    /// @notice The widest a currency quote may be and still be taken seriously, WAD.
    /// @dev Both conversion legs are prices of a currency in a unit of account. A rate outside
    ///      1e-18 and 1e18 is not one of those, whatever the feed says, so it reads as a failure
    ///      and freezes rather than being composed into a market price. This also bounds the
    ///      arithmetic: with both legs inside it, and the quote saturated at `type(uint208).max`,
    ///      the composition below has an exactly-known worst case.
    uint256 internal constant MAX_QUOTE = 1e36;

    // --- Types -------------------------------------------------------------------------------

    /// @dev What a read of all three feeds resolved to. `PAUSED` covers a zero NAV and every
    ///      unreadable shape of the wsgem's own feed; `LIVE_ZERO` is a live NAV whose redemption
    ///      quote is zero; `FX_DOWN` is a healthy wsgem whose conversion legs are not usable;
    ///      `QUOTE` carries a real price, one wei included.
    enum Spot {
        PAUSED,
        LIVE_ZERO,
        FX_DOWN,
        QUOTE
    }

    /// @dev What shape the borrowed token's quote source has. Two exist because the two borrowed
    ///      tokens this repo lists against have different best sources, not because generality was
    ///      wanted for its own sake: crvUSD has Curve's own aggregator, which is what Curve's crvUSD
    ///      markets read and what carries no heartbeat to go stale; frxUSD has no such contract and
    ///      does have a dedicated Chainlink feed. Routing the second through a Curve pool to force
    ///      one shape would rest the market on a single fourteen-minute pool average instead of an
    ///      OCR set, which is worse, so both shapes are supported and each instance names its own.
    enum QuoteKind {
        CURVE_AGGREGATOR,
        CHAINLINK_FEED
    }

    // --- Immutables --------------------------------------------------------------------------

    /// @notice The wsgem this oracle prices.
    IWsgem public immutable WSGEM;

    /// @notice The gem the wsgem's redemption quote is denominated in. Read from the wsgem.
    /// @dev NOT the borrowed token. Keeping both is what lets a deploy script tell an oracle built
    ///      for this market from one built for the same wsgem against a different borrowed asset --
    ///      a confusion nothing on-chain can otherwise catch, because every other field matches.
    address public immutable GEM;

    /// @notice The token the market borrows, and the currency `price()` is denominated in.
    address public immutable BORROWED;

    /// @notice The wsgem's price feed, cached at construction. The sole pause authority.
    IPip public immutable PIP;

    /// @notice Price of the gem's currency in the shared unit of account. Chainlink push feed.
    IChainlinkAggregator public immutable FX_FEED;

    /// @notice `10 ** (18 - FX_FEED.decimals())`, so a raw answer scales to WAD by multiplication.
    /// @dev Computed once. A feed's decimals are fixed for its life, proxy phase changes included,
    ///      so this is the one thing about the feed it is safe to cache.
    uint256 public immutable FX_SCALE;

    /// @notice Price of the borrowed token in the same unit of account. Shape given by
    ///         `BORROWED_QUOTE_KIND`: a WAD `price()` view, or a Chainlink round.
    address public immutable BORROWED_QUOTE;

    /// @notice Which of the two shapes `BORROWED_QUOTE` has.
    QuoteKind public immutable BORROWED_QUOTE_KIND;

    /// @notice `10 ** (18 - decimals)` for a Chainlink-shaped borrowed quote; one for a Curve
    ///         aggregator, which already answers in WAD.
    uint256 public immutable BORROWED_QUOTE_SCALE;

    /// @notice How old a Chainlink answer may be before it reads as a halted feed, seconds.
    /// @dev Applies to `FX_FEED` always, and to `BORROWED_QUOTE` when that is a Chainlink feed too.
    ///      One bound for both because both are Chainlink push feeds on the same 24-hour heartbeat;
    ///      a Curve aggregator has no publication time and nothing to bound.
    uint256 public immutable MAX_FX_AGE;

    /// @notice Maximum relative increase in the RATE-LIMITED LEG, per second, scaled by 1e18.
    /// @dev The leg, not the price. See the contract note on where the rate limit binds.
    uint256 public immutable MAX_UPSIDE_SPEED;

    // --- Storage -----------------------------------------------------------------------------
    // Two slots, and the reason there are two is the whole design. The sibling's anchor and its
    // last report are the same number, so one word holds both. Here they are different numbers in
    // different units -- the anchor is a quote in gem terms, the report is a price in borrowed-token
    // terms -- and the conversion between them can fail on its own. Both are needed.

    /// @notice Slot one: the rate-limit anchor, in GEM terms. The last QUOTE-state redemption quote
    ///         `price_w` accepted, after the limit. Never zero after construction.
    /// @dev Deliberately pre-conversion, so movement in the conversion legs never consumes upside
    ///      allowance and a quiet week of foreign exchange never buys the NAV a free jump.
    uint208 public cachedQuote;

    /// @notice When the checkpoint was last touched. Refreshed by every `price_w`, freezes and
    ///         live-zero reports included, so no upside allowance accrues through either.
    uint40 public cachedTimestamp;

    /// @notice Whether the last `price_w` report was the one-wei live-zero floor.
    bool public liveZeroReported;

    /// @notice Slot two: the last price reported in the QUOTE state, in BORROWED-token terms.
    ///         What a freeze holds. Never zero after construction.
    uint208 public cachedPrice;

    /// @notice Whether the last `price_w` found the conversion legs unusable.
    /// @dev Only here to make the `FxDown`/`FxRestored` transition eventable once rather than on
    ///      every call. It shares slot two, so maintaining it costs no extra cold word.
    bool public fxDown;

    // --- Errors ------------------------------------------------------------------------------

    error ZeroAddress();
    error UnsupportedDecimals();
    error OraclePaused();
    error QuoteIsZero();
    error SpeedTooHigh();
    error FxAgeOutOfBounds();
    error FxUnusable();

    // --- Events ------------------------------------------------------------------------------

    /// @notice Emitted by `price_w` whenever the reported price moves.
    /// @param price The newly reported price, WAD borrowed-token-per-wsgem.
    /// @param spot  The undamped composed price at that moment.
    event PriceUpdated(uint256 indexed price, uint256 indexed spot);

    /// @notice Emitted by `price_w` whenever the rate-limit anchor moves.
    /// @param quote The newly anchored redemption quote, WAD gem-per-wsgem.
    /// @dev Separate from `PriceUpdated` because the two move for different reasons: this one only
    ///      when the NAV leg does, that one whenever any leg does. Watching both is how an operator
    ///      tells a publication from a currency move without leaving the logs.
    event QuoteAnchored(uint256 indexed quote);

    /// @notice Emitted by `price_w` when the report enters the one-wei live-zero floor.
    event QuoteZeroed(uint256 indexed anchor);

    /// @notice Emitted by `price_w` when the report leaves the floor.
    event QuoteRestored(uint256 indexed price);

    /// @notice Emitted by `price_w` when the conversion legs stop being usable.
    /// @param price The price being held for the duration.
    event FxDown(uint256 indexed price);

    /// @notice Emitted by `price_w` when the conversion legs become usable again.
    event FxRestored(uint256 indexed price);

    // --- Construction ------------------------------------------------------------------------

    /// @param wsgem_              The wsgem to price. Must be 18 decimals, over an 18-decimal gem.
    /// @param borrowed_           The market's borrowed token. Must be 18 decimals.
    /// @param fxFeed_             Chainlink feed for the gem's currency in the shared unit of
    ///                            account.
    /// @param borrowedQuoteSource_ Price of `borrowed_` in that same unit of account.
    /// @param borrowedQuoteKind_  Which shape `borrowedQuoteSource_` has.
    /// @param maxUpsideSpeed_     Maximum relative increase in the NAV leg per second, WAD-scaled.
    /// @param maxFxAge_           Staleness bound on the Chainlink legs, seconds. Must exceed their
    ///                            heartbeat.
    constructor(
        IWsgem wsgem_,
        address borrowed_,
        IChainlinkAggregator fxFeed_,
        address borrowedQuoteSource_,
        QuoteKind borrowedQuoteKind_,
        uint256 maxUpsideSpeed_,
        uint256 maxFxAge_
    ) {
        if (
            address(wsgem_) == address(0) || borrowed_ == address(0) || address(fxFeed_) == address(0)
                || borrowedQuoteSource_ == address(0)
        ) revert ZeroAddress();
        if (maxUpsideSpeed_ == 0 || maxUpsideSpeed_ > MAX_UPSIDE_SPEED_LIMIT) revert SpeedTooHigh();
        if (maxFxAge_ < MIN_FX_AGE_LIMIT || maxFxAge_ > MAX_FX_AGE_LIMIT) revert FxAgeOutOfBounds();

        address gem_ = wsgem_.gem();
        address pip_ = wsgem_.pip();
        if (gem_ == address(0) || pip_ == address(0)) revert ZeroAddress();

        // Two separate identities, both WAD, and both must hold for the composition to be a plain
        // multiply-divide with no token-decimals term anywhere. The wsgem/gem pair is what makes
        // `burncost()` a WAD quote; the borrowed token's 18 decimals are what make the converted
        // result a WAD price. An 18/non-18 pair needs a scaling term this contract deliberately
        // does not carry -- the same refusal the sibling makes, one token wider.
        if (wsgem_.decimals() != 18 || IDecimals(gem_).decimals() != 18) revert UnsupportedDecimals();
        if (IDecimals(borrowed_).decimals() != 18) revert UnsupportedDecimals();

        // Read once, unguarded and outside the gas cap: a feed whose `decimals()` cannot be read at
        // construction is not one to build a market on, and reverting here is free. Above 18 the
        // scale would be a fraction, which this contract does not carry either.
        uint8 fxDecimals_ = fxFeed_.decimals();
        if (fxDecimals_ > 18) revert UnsupportedDecimals();

        uint256 borrowedScale_ = 1;
        if (borrowedQuoteKind_ == QuoteKind.CHAINLINK_FEED) {
            uint8 borrowedDecimals_ = IChainlinkAggregator(borrowedQuoteSource_).decimals();
            if (borrowedDecimals_ > 18) revert UnsupportedDecimals();
            borrowedScale_ = 10 ** (18 - borrowedDecimals_);
        }

        WSGEM                = wsgem_;
        GEM                  = gem_;
        BORROWED             = borrowed_;
        PIP                  = IPip(pip_);
        FX_FEED              = fxFeed_;
        FX_SCALE             = 10 ** (18 - fxDecimals_);
        BORROWED_QUOTE       = borrowedQuoteSource_;
        BORROWED_QUOTE_KIND  = borrowedQuoteKind_;
        BORROWED_QUOTE_SCALE = borrowedScale_;
        MAX_FX_AGE           = maxFxAge_;
        MAX_UPSIDE_SPEED     = maxUpsideSpeed_;

        // Refuse to deploy against anything but a fully healthy set of feeds. There would be no
        // last-good price to freeze at, and no basis for a market's opening band.
        (Spot state_, uint256 quote_, uint256 fx_, uint256 borrowedQuote_) = _spot();
        if (state_ == Spot.PAUSED) revert OraclePaused();
        if (state_ == Spot.LIVE_ZERO) revert QuoteIsZero();
        if (state_ == Spot.FX_DOWN) revert FxUnusable();

        uint256 price_ = _compose(quote_, fx_, borrowedQuote_);

        cachedQuote     = _toUint208(quote_); // already saturated by _spot; the clamp is free
        cachedPrice     = _toUint208(price_); // _compose saturates
        cachedTimestamp = uint40(block.timestamp);

        emit QuoteAnchored(quote_);
        emit PriceUpdated(price_, price_);
    }

    // --- Llamalend price oracle --------------------------------------------------------------

    /// @notice Price of one wsgem in the borrowed token, scaled by 1e18.
    /// @dev Never returns zero. See the contract-level note for what happens when the wsgem's feed
    ///      is paused or quotes zero, and when the conversion legs are unusable.
    function price() external view returns (uint256) {
        (Spot state_, uint256 quote_, uint256 fx_, uint256 borrowedQuote_) = _spot();
        return _price(state_, quote_, fx_, borrowedQuote_);
    }

    /// @notice Same value as `price()`, persisting the rate-limit checkpoint.
    /// @dev Deliberately permissionless, for the same reason as the sibling: the checkpoint only
    ///      ever moves the anchored quote toward the feed, bounded by `MAX_UPSIDE_SPEED`, so there
    ///      is nothing to gain by sampling. Under normal operation the AMM drives it.
    function price_w() external returns (uint256) {
        (Spot state_, uint256 quote_, uint256 fx_, uint256 borrowedQuote_) = _spot();

        // ORDER MATTERS, and it is the one ordering hazard this contract has. `_limit` reads
        // `cachedTimestamp` through `_ceiling`, and the write below overwrites it -- so the limited
        // quote MUST be taken before the checkpoint moves, or every call computes a ceiling over
        // zero elapsed time, the anchor never advances, and the rate limit becomes a permanent cap
        // instead of a delay. Pinned by test_aLargeNavRiseEventuallyArrives.
        uint256 limited_;
        uint256 price_;
        if (state_ == Spot.QUOTE) {
            limited_ = _limit(quote_);
            price_   = _compose(limited_, fx_, borrowedQuote_);
        } else {
            price_ = _price(state_, quote_, fx_, borrowedQuote_);
        }

        // Always refresh the timestamp, including through a freeze. The rate limit measures time
        // since the last anchored quote, and a freeze anchors the same quote again -- letting
        // allowance accrue across a pause would hand the feed a free jump on the way out.
        cachedTimestamp = uint40(block.timestamp);

        if (state_ == Spot.LIVE_ZERO) {
            // The floor is reported but never anchored: it is a failure state, not a price to
            // ratchet from. Keeping the last real anchor is what lets a restored quote return --
            // downward at full speed, upward bounded by the anchor's own ceiling -- rather than
            // ratcheting up from one wei. The transition is evented once, not per call.
            if (!liveZeroReported) {
                liveZeroReported = true;
                emit QuoteZeroed(cachedQuote);
            }
        } else if (state_ == Spot.FX_DOWN) {
            // Nothing is anchored either: the NAV leg may be perfectly healthy, but accepting its
            // quote here would let the anchor ratchet up unobserved behind a dark conversion and
            // spend the whole of that time's allowance the moment the currency feed returns.
            if (!fxDown) {
                fxDown = true;
                emit FxDown(price_);
            }
        } else if (state_ == Spot.QUOTE) {
            if (liveZeroReported) {
                liveZeroReported = false;
                emit QuoteRestored(price_);
            }
            if (fxDown) {
                fxDown = false;
                emit FxRestored(price_);
            }

            if (limited_ != cachedQuote) {
                cachedQuote = _toUint208(limited_); // <= quote, already saturated by _spot
                emit QuoteAnchored(limited_);
            }
            if (price_ != cachedPrice) {
                cachedPrice = _toUint208(price_); // _compose saturates
                emit PriceUpdated(price_, _compose(quote_, fx_, borrowedQuote_));
            }
        }
        // PAUSED mutates nothing beyond the timestamp: a freeze preserves the last report, the
        // live-zero and conversion flags included.

        return price_;
    }

    // --- Views -------------------------------------------------------------------------------

    /// @notice The undamped composed price -- the live redemption quote converted at the live rate,
    ///         with no rate limit applied. Zero in every failure state.
    /// @dev For monitoring: a persistent `price() < spotPrice()` means the rate limit is binding on
    ///      the NAV leg, which in ordinary operation it should not be. `frozen()`, `fxFrozen()` and
    ///      `quoteIsZero()` tell the failure states apart.
    function spotPrice() external view returns (uint256) {
        (Spot state_, uint256 quote_, uint256 fx_, uint256 borrowedQuote_) = _spot();
        return state_ == Spot.QUOTE ? _compose(quote_, fx_, borrowedQuote_) : 0;
    }

    /// @notice The wrapper's live redemption quote in gem terms, undamped, saturated. Zero when the
    ///         wsgem's own feed is paused or its quote is zero -- and NOT zero merely because the
    ///         conversion legs are down, which this leg knows nothing about.
    function quotePrice() external view returns (uint256) {
        (Spot state_, uint256 quote_,,) = _spot();
        return state_ == Spot.PAUSED || state_ == Spot.LIVE_ZERO ? 0 : quote_;
    }

    /// @notice The live conversion factor: gem currency per borrowed token, WAD. Zero when either
    ///         conversion leg is unreadable, stale or absurd.
    /// @dev The other half of `quotePrice()`. Between them an operator can see which leg is dark
    ///      without decoding a frozen price.
    function fxRate() external view returns (uint256) {
        (bool ok_, uint256 fx_, uint256 borrowedQuote_) = _readFx();
        return ok_ ? _mulDivSat(fx_, WAD, borrowedQuote_) : 0;
    }

    /// @notice The highest quote `price_w` could anchor right now, in GEM terms.
    /// @dev In quote terms, not price terms -- this is the ceiling on the rate-limited leg. Equals
    ///      `cachedQuote` when no time has passed.
    function quoteCeiling() external view returns (uint256) {
        return _ceiling();
    }

    /// @notice Whether the reported price is frozen at its last value, for any reason.
    function frozen() external view returns (bool) {
        (Spot state_,,,) = _spot();
        return state_ == Spot.PAUSED || state_ == Spot.FX_DOWN;
    }

    /// @notice Whether the freeze is specifically the conversion legs rather than the wsgem's feed.
    function fxFrozen() external view returns (bool) {
        (Spot state_,,,) = _spot();
        return state_ == Spot.FX_DOWN;
    }

    /// @notice Whether the wsgem's feed is live but the redemption quote is zero -- a 100% spread.
    ///         The reported price is one wei and is not being anchored.
    function quoteIsZero() external view returns (bool) {
        (Spot state_,,,) = _spot();
        return state_ == Spot.LIVE_ZERO;
    }

    // --- Internals ---------------------------------------------------------------------------

    /// @notice What the feeds currently resolve to: the state, the raw quote, and the composed spot.
    /// @dev Order matters and is the same as the sibling's for the same reasons. The NAV is read
    ///      first and is the sole pause authority -- `burncost()`'s last hop sits behind an
    ///      upgradeable proxy of its own, so a nonzero quote does not prove the feed is live. A
    ///      zero quote short-circuits before the conversion legs are read at all: collateral that
    ///      redeems for nothing redeems for nothing in any currency, and there is no reason to
    ///      spend a million gas of aggregator read establishing it.
    function _spot()
        internal
        view
        returns (Spot state_, uint256 quote_, uint256 fx_, uint256 borrowedQuote_)
    {
        (bool okNav_, uint256 nav_) = _readWord(address(PIP), abi.encodeCall(IPip.read, ()), PIP_READ_GAS);
        if (!okNav_ || nav_ == 0) return (Spot.PAUSED, 0, 0, 0);

        bool okQuote_;
        (okQuote_, quote_) = _readWord(address(WSGEM), abi.encodeCall(IWsgem.burncost, ()), PIP_READ_GAS);
        if (!okQuote_) return (Spot.PAUSED, 0, 0, 0);
        if (quote_ == 0) return (Spot.LIVE_ZERO, 0, 0, 0);

        quote_ = uint256(_toUint208(quote_));

        bool okFx_;
        (okFx_, fx_, borrowedQuote_) = _readFx();
        if (!okFx_) return (Spot.FX_DOWN, quote_, 0, 0);

        return (Spot.QUOTE, quote_, fx_, borrowedQuote_);
    }

    /// @notice Both conversion legs, in the same unit of account, WAD.
    /// @dev Fails closed on every shape of trouble: a revert, a short return, a gas burn, a
    ///      non-positive or absurd answer, a missing or stale publication time, an unreadable or
    ///      zero aggregator. Each of those is the same statement -- "this conversion is not
    ///      usable" -- and the caller's response to all of them is to freeze.
    function _readFx() internal view returns (bool ok_, uint256 fx_, uint256 borrowedQuote_) {
        bool okGem_;
        (okGem_, fx_) = _readChainlink(address(FX_FEED), FX_SCALE);
        if (!okGem_) return (false, 0, 0);

        bool okBorrowed_;
        (okBorrowed_, borrowedQuote_) = BORROWED_QUOTE_KIND == QuoteKind.CHAINLINK_FEED
            ? _readChainlink(BORROWED_QUOTE, BORROWED_QUOTE_SCALE)
            : _readWord(
                BORROWED_QUOTE, abi.encodeCall(IStablePriceAggregator.price, ()), QUOTE_AGGREGATOR_READ_GAS
            );
        if (!okBorrowed_) return (false, 0, 0);

        if (fx_ == 0 || fx_ > MAX_QUOTE || borrowedQuote_ == 0 || borrowedQuote_ > MAX_QUOTE) {
            return (false, 0, 0);
        }

        return (true, fx_, borrowedQuote_);
    }

    /// @notice One Chainlink leg, scaled to WAD. `(false, 0)` on anything that is not a usable,
    ///         positive, fresh answer.
    function _readChainlink(address feed_, uint256 scale_)
        internal
        view
        returns (bool ok_, uint256 quote_)
    {
        (bool okFeed_, int256 answer_, uint256 updatedAt_) = _readRound(feed_);
        if (!okFeed_ || answer_ <= 0 || updatedAt_ == 0) return (false, 0);

        // A round stamped AFTER the block reading it is malformed, and malformed is a failure.
        // `updatedAt` is the block timestamp of the transmit that wrote the round, and block
        // timestamps are monotonic, so a future stamp cannot arise from an honest feed on this
        // chain -- it means the contract at this address is not answering the way a Chainlink
        // aggregator answers.
        //
        // Crediting it as "current" instead would be worse than useless: it would disable the age
        // bound entirely for as long as the stamp stayed ahead of the chain, which is exactly the
        // window in which a halted feed most needs catching. Freeze instead.
        //
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt_ > block.timestamp) return (false, 0);

        // The comparison is against a bound measured in tens of hours, so the seconds a proposer
        // can shift the clock by are not a lever on it -- the same reasoning the rate calculator
        // records at its own timestamp comparisons.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt_ > MAX_FX_AGE) return (false, 0);

        // Saturating multiply: an absurd answer must fail the caller's bound, not wrap under it.
        // The cast is safe because the sign was rejected above: `answer_` is strictly positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw_ = uint256(answer_);
        if (raw_ > type(uint256).max / scale_) return (false, 0);

        return (true, raw_ * scale_);
    }

    /// @dev Gas-capped, one-word staticcall: a revert, a short return, a gas burn or an oversized
    ///      payload all come back as `(false, 0)` rather than propagating.
    function _readWord(address target_, bytes memory data_, uint256 gas_)
        internal
        view
        returns (bool ok_, uint256 word_)
    {
        uint256 size_;
        assembly ("memory-safe") {
            ok_   := staticcall(gas_, target_, add(data_, 0x20), mload(data_), 0x00, 0x20)
            size_ := returndatasize()
            word_ := mload(0x00)
        }
        if (!ok_ || size_ < 32) return (false, 0);
        return (ok_, word_);
    }

    /// @dev The same discipline as `_readWord` over a five-word return. Only the second and fourth
    ///      words are load-bearing; a return shorter than five words is a feed that is not the feed
    ///      this contract was built against, and reads as a failure.
    function _readRound(address feed_) internal view returns (bool ok_, int256 answer_, uint256 updatedAt_) {
        bytes memory data_ = abi.encodeCall(IChainlinkAggregator.latestRoundData, ());
        uint256 gas_ = FX_FEED_READ_GAS;
        uint256 size_;
        assembly ("memory-safe") {
            // Scratch beyond the free memory pointer, never published: the pointer is deliberately
            // not advanced, and nothing here outlives this block.
            let out_ := mload(0x40)
            ok_        := staticcall(gas_, feed_, add(data_, 0x20), mload(data_), out_, 0xa0)
            size_      := returndatasize()
            answer_    := mload(add(out_, 0x20))
            updatedAt_ := mload(add(out_, 0x60))
        }
        if (!ok_ || size_ < 0xa0) return (false, 0, 0);
        return (ok_, answer_, updatedAt_);
    }

    /// @notice The reported price for a given feed reading.
    /// @dev Pure with respect to the checkpoint, which is what makes `price()` and `price_w()`
    ///      agree within a call. A freeze holds the last REPORT -- the one-wei floor included, when
    ///      that is what was last reported -- not something recomputed from the anchor.
    function _price(Spot state_, uint256 quote_, uint256 fx_, uint256 borrowedQuote_)
        internal
        view
        returns (uint256)
    {
        if (state_ == Spot.PAUSED || state_ == Spot.FX_DOWN) {
            return liveZeroReported ? LIVE_ZERO_PRICE : cachedPrice; // frozen: never zero
        }
        if (state_ == Spot.LIVE_ZERO) return LIVE_ZERO_PRICE;

        // The limit binds on the quote, so the reported price is the conversion of the LIMITED
        // quote -- not the limit of the converted price. Conversion is monotone in the quote, so
        // the result is still bounded above by the composed spot, which is what `spotPrice()`
        // reports and what the deploy scripts assert the reported price against.
        return _compose(_limit(quote_), fx_, borrowedQuote_);
    }

    /// @dev `min(quote, ceiling)`. Split out so `price_w` can re-derive exactly what `_price` used.
    function _limit(uint256 quote_) internal view returns (uint256) {
        uint256 ceiling_ = _ceiling();
        return quote_ < ceiling_ ? quote_ : ceiling_;
    }

    /// @dev `quote * fx / borrowedQuote`, floored at one wei and saturated at `type(uint208).max`.
    ///      Full precision: with the quote saturated at 2^208 and both legs bounded by `MAX_QUOTE`,
    ///      the intermediate product genuinely can exceed 2^256, and the market must not revert
    ///      when it does.
    function _compose(uint256 quote_, uint256 fx_, uint256 borrowedQuote_) internal pure returns (uint256) {
        uint256 p_ = _mulDivSat(quote_, fx_, borrowedQuote_);
        return p_ == 0 ? LIVE_ZERO_PRICE : p_;
    }

    /// @notice `cachedQuote` grown by `MAX_UPSIDE_SPEED` over the elapsed time, capped.
    /// @dev Saturating rather than reverting on overflow. A revert here would propagate into every
    ///      AMM read and brick the market -- and saturation is harmless, because the result is only
    ///      ever used as an upper bound on the feed reading. With the anchor saturated at uint208
    ///      the addition below cannot overflow, so its guard is unreachable; kept anyway, because
    ///      this block is unchecked and the guard is the only net if the anchor is ever widened.
    function _ceiling() internal view returns (uint256) {
        uint256 cached_  = cachedQuote;
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

    /// @notice Full-precision `x * y / d`, saturating at `type(uint208).max` and at zero divisor.
    /// @dev The 512-bit long-division of Remco Bloemen's `mulDiv`, with every revert replaced by a
    ///      saturation for the reason `_ceiling` saturates: a price oracle that reverts is a market
    ///      that cannot be repaid or liquidated. Callers only ever pass a zero divisor if a feed
    ///      returned zero, which is already rejected upstream; the guard is belt to that brace.
    ///
    ///      In every realistic call the high word is zero and this is one `div`. The long path
    ///      exists because "realistic" is not a guarantee a market can rest on.
    function _mulDivSat(uint256 x_, uint256 y_, uint256 d_) internal pure returns (uint256) {
        // Unreachable from either caller -- a zero borrowed quote is rejected upstream as FX_DOWN
        // -- and deliberately kept, in the same spirit as `_ceiling`'s overflow guards: it costs
        // one comparison and it is the only net if a future caller forgets. Both are why this
        // contract's branch coverage stops short of 100% while its lines and functions do not.
        if (d_ == 0) return type(uint208).max;

        uint256 lo_;
        uint256 hi_;
        unchecked {
            uint256 mm_ = mulmod(x_, y_, type(uint256).max);
            lo_ = x_ * y_;
            hi_ = mm_ - lo_;
            if (mm_ < lo_) hi_--;
        }

        // Fits in one word: the ordinary case, and the only one a healthy market ever reaches.
        if (hi_ == 0) {
            uint256 q_ = lo_ / d_;
            return q_ > type(uint208).max ? type(uint208).max : q_;
        }

        // The quotient is at least 2^256, which is past the cap by a wide margin.
        if (hi_ >= d_) return type(uint208).max;

        unchecked {
            // Make the 512-bit numerator exactly divisible by subtracting the remainder.
            uint256 remainder_ = mulmod(x_, y_, d_);
            if (remainder_ > lo_) hi_--;
            lo_ -= remainder_;

            // Factor the powers of two out of the divisor, shifting the numerator down with it.
            uint256 twos_ = d_ & (0 - d_);
            d_  /= twos_;
            lo_ /= twos_;
            // 2^256 / twos_, which is exactly the left shift the high word needs. When the divisor
            // was already odd this wraps to zero, and zero is correct: nothing shifts down.
            twos_ = (0 - twos_) / twos_ + 1;
            lo_ |= hi_ * twos_;

            // Newton-Raphson on the odd divisor's inverse mod 2^256: four correct bits, doubling.
            uint256 inv_ = (3 * d_) ^ 2;
            inv_ *= 2 - d_ * inv_; //   8 bits
            inv_ *= 2 - d_ * inv_; //  16
            inv_ *= 2 - d_ * inv_; //  32
            inv_ *= 2 - d_ * inv_; //  64
            inv_ *= 2 - d_ * inv_; // 128
            inv_ *= 2 - d_ * inv_; // 256

            uint256 q_ = lo_ * inv_;
            return q_ > type(uint208).max ? type(uint208).max : q_;
        }
    }

    /// @dev Saturating, not truncating -- the same clamp the rate calculator applies to what it
    ///      stores, for the same reason: a reading past 2.6e62 in WAD is already nonsense, and
    ///      saturating keeps it from wrapping to a small number that would read as a collapse.
    function _toUint208(uint256 x_) internal pure returns (uint208) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x_ > type(uint208).max ? type(uint208).max : uint208(x_);
    }
}
