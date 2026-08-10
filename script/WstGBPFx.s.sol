// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";

import {WsgemLlamalendScript} from "./WsgemLlamalendDeploy.s.sol";

import {WsgemFxLlamalendOracle} from "../src/WsgemFxLlamalendOracle.sol";
import {IWsgem}                 from "../src/interfaces/IWsgem.sol";
import {IWsgemShimOracle}       from "../src/interfaces/IWsgemShimOracle.sol";
import {IChainlinkAggregator}   from "../src/interfaces/IChainlinkAggregator.sol";

/// @title WstGBPFxConstants
/// @notice Everything the cross-currency wstGBP instances share: the collateral, its feed, the
///         sterling leg, and a risk parameter set that answers for foreign-exchange volatility.
/// @dev What varies between those instances is exactly three things -- which dollar stablecoin is
///      borrowed, where its dollar quote comes from, and what shape that source has. Everything
///      else is a property of pricing wstGBP in dollars at all, and is stated here once. Copying
///      this file per borrowed token would duplicate the reasoning below without duplicating any
///      decision, and nothing in the test suite catches prose drifting apart.
///
///      Every value here is asserted by each instance's OWN suite --
///      test/WstGBPCrvUSDDeployScript.t.sol and test/WstGBPFrxUSDDeployScript.t.sol -- reading it
///      through that instance's script rather than through this base. A suite that read these
///      values from here would prove only that the base is self-consistent with itself.
abstract contract WstGBPFxConstants {
    // --- The collateral ------------------------------------------------------------------------
    //
    // The same wsgem the first instance lists, reading the same feed on the same weekly cadence.
    // The gem is tGBP, and it is NOT what these markets borrow -- which is the whole difference.
    // The wrapper's WAD redemption quote is denominated in tGBP, so it is not Llamalend's
    // collateral-in-borrowed price here; it is one term of it.

    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant TGBP   = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    // --- The sterling leg ----------------------------------------------------------------------
    //
    //   price = burncost (tGBP per wstGBP)  x  GBP/USD  /  <borrowed>/USD

    /// @dev Chainlink's GBP/USD push aggregator: `AggregatorV3`, 8 decimals, 24-hour heartbeat and
    ///      a 0.15% deviation threshold, so in practice it updates far more often than daily. It
    ///      publishes through weekends -- rounds land on Saturdays and Sundays -- so the staleness
    ///      bound needs no foreign-exchange market-hours carve-out. This is a proxy; Chainlink can
    ///      repoint it at a phase change, which is how a feed is upgraded without consumers moving.
    ///
    ///      A Chainlink DATA STREAM also exists for this pair
    ///      (`GBP/USD-Streams-ForexPrice-DS-Premium-Global-008`, feed id
    ///      `0x00086bdceb0b66669c04e7315815614f4ad910e6bb0134e2a7b9070145eb2e7b`) and is lower
    ///      latency. It is not usable here and no amount of parameterisation makes it so: Data
    ///      Streams is pull-based, a signed report fetched off-chain and verified in a payable
    ///      transaction, and Llamalend reads `price()` as a `view` from inside the AMM. Consuming
    ///      one would mean a keeper pushing verified reports into a storage contract --
    ///      reintroducing exactly the discretionary party this repo's ownerlessness exists to
    ///      remove.
    ///
    ///      Precedent for this specific address: the WETH/tGBP Morpho Blue market
    ///      (`0xa4942ce9152aaeb5cab0403d8b3ba08142b61460b4776e6fd4a83d234d309d0c`) already sources
    ///      GBP/USD from it as its quote feed.
    address internal constant GBP_USD_FEED = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;

    /// @dev Thirty hours against the 24-hour heartbeat both Chainlink legs carry: one missed
    ///      publication is tolerated by six hours, and past that the conversion reads as a halted
    ///      feed and the reported price freezes. Sized off the heartbeat rather than off the
    ///      deviation cadence deliberately -- a quiet currency legitimately produces nothing but
    ///      heartbeat rounds, and a bound tight enough to notice that would freeze the market every
    ///      quiet weekend.
    uint256 internal constant MAX_FX_AGE_WSTGBP_FX = 30 hours;

    // --- Oracle shim ---------------------------------------------------------------------------

    /// @dev Identical to the first instance, and deliberately so: the rate limit binds on the NAV
    ///      leg alone, and the NAV leg here is the same wsgem publishing on the same weekly cadence
    ///      at the same ~6.8 basis points. Nothing about borrowing a different token changes what a
    ///      mistaken publication would look like or how fast it should be allowed to propagate.
    ///
    ///      The conversion is NOT rate-limited, and that is the design rather than an omission. A
    ///      foreign-exchange rate is traded, two-sided, and moves a percent on an ordinary day;
    ///      throttling it would under-report collateral through every sterling rally and
    ///      soft-liquidate healthy borrowers for the privilege, while guarding nothing -- the
    ///      hazard the limit exists for is a mistaken ADMINISTERED publication, and Chainlink's
    ///      OCR set is not that.
    uint256 internal constant MAX_UPSIDE_SPEED_WSTGBP_FX = uint256(0.0025e18) / 1 days;

    // --- Rate calculator -----------------------------------------------------------------------
    //
    // All three carried over unchanged from the first instance: same feed, same cadence, same
    // cadence-bridge argument. See script/WstGBP.s.sol and docs/03 for the reasoning, which is
    // about the feed and not about the market built on it.
    //
    // What DOES change is what the measurement means. The calculator reports the collateral's
    // realised yield -- a sterling yield -- and the monetary policy takes it as the target borrow
    // rate. Against tGBP debt that makes a loop roughly break-even at target utilization. Against
    // dollar debt it does not: dollar rates are not sterling rates, and the loop is a currency
    // carry trade. Reusing the calculator anyway is a deliberate choice, recorded in
    // docs/04-parameters.md, not an oversight.

    uint256 internal constant RATE_INTERVALS_WSTGBP_FX         = 4;
    uint256 internal constant MAX_PUBLICATION_GAP_WSTGBP_FX    = 10 days;
    uint256 internal constant MIN_CHECKPOINT_SPACING_WSTGBP_FX = 1 days;

    // --- Risk parameters -----------------------------------------------------------------------
    //
    // Taken from Curve's svZCHF/crvUSD market -- controller
    // 0xFd85e847cDd2549f213E276e4B57B0690169F043 on the same V2 mainnet factory -- which is the
    // closest published analogue by a distance: a foreign-currency yield-bearing wrapper borrowed
    // against a dollar stablecoin, which is this market with the Swiss franc swapped for sterling.
    // It is a far better donor than the sDOLA/crvUSD set the first instance inherited, and using
    // that set here would be actively wrong: 35 basis point bands against a currency pair that
    // moves a percent on an ordinary day would leave borrowers permanently in soft liquidation.
    //
    // Review before broadcast -- see docs/04-parameters.md.

    /// @dev Band width is roughly 1/A, so 180 gives about 56 basis points per band. svZCHF/crvUSD's
    ///      value exactly.
    uint256 internal constant A_WSTGBP_FX = 180;

    /// @dev 0.05%, svZCHF/crvUSD's value. The AMM caps this at min(1e18 * 4 / A, 10%) = about 2.22%
    ///      at A = 180, so there is a great deal of room above it; the constraint is economic, not
    ///      mechanical.
    uint256 internal constant FEE_WSTGBP_FX = 0.0005e18;

    /// @dev 5%, which is svZCHF/crvUSD's 4.3% plus 70 basis points, and the 70 is the one number in
    ///      this file that is ours rather than inherited.
    ///
    ///      What it pays for: svZCHF/crvUSD's oracle composes Curve pool moving averages, which
    ///      move with every trade. Ours composes a Chainlink push feed, which moves only when a
    ///      round fires -- triggered at 0.15% on GBP/USD. In a calm market the reported sterling
    ///      price therefore sits routinely around that far behind, in either direction, with no
    ///      failure having occurred, and seventy basis points is roughly four times that typical
    ///      lag -- the difference between a borrower opening a position at what the market says and
    ///      opening it at what the feed last said.
    ///
    ///      The threshold TRIGGERS a round; it does not cap one. A move that outruns a round leaves
    ///      the price further behind by however much the market travelled while the round was
    ///      proposed, agreed and transmitted, and a leg recovering from a freeze delivers the whole
    ///      accumulated move at once. This buffer is sized against the ordinary case and
    ///      deliberately not against the fast one.
    ///
    ///      It does NOT cover an arbitrarily fast move -- nothing in a discount does, and that is
    ///      what the liquidation discount below and the borrow cap are for.
    uint256 internal constant LOAN_DISCOUNT_WSTGBP_FX = 0.05e18;

    /// @dev 2.3%, svZCHF/crvUSD's value, left alone. Widening the loan discount and leaving this
    ///      is the deliberate shape: it moves where a borrower may OPEN without moving where
    ///      liquidation begins, so the extra buffer is spent on the borrower's entry rather than on
    ///      giving a soft-liquidating position more room to keep losing.
    uint256 internal constant LIQUIDATION_DISCOUNT_WSTGBP_FX = 0.023e18;

    /// @dev Unlimited vault deposits, as the first instance. This is not the borrow cap -- that is
    ///      separate, starts at zero, and only a Curve DAO vote can lift it.
    uint256 internal constant SUPPLY_LIMIT_WSTGBP_FX = type(uint256).max;

    // --- Monetary policy curve -------------------------------------------------------------------
    //
    // Carried over from the first instance, which took them from sDOLA/crvUSD. svZCHF/crvUSD is not
    // a donor here: it does not run `HyperbolicDynamicMP` at all, so it has no curve to copy.

    uint256 internal constant TARGET_UTILIZATION_WSTGBP_FX = 0.90e18;
    uint256 internal constant LOW_RATIO_WSTGBP_FX          = 0.5e18; // 0.5x base at 0% utilization
    uint256 internal constant HIGH_RATIO_WSTGBP_FX         = 5e18;   // 5x base at 100% utilization
    uint256 internal constant RATE_SHIFT_WSTGBP_FX         = 0;
}

/// @title WstGBPFxScript
/// @notice The shared behaviour of every cross-currency wstGBP instance: which oracle to deploy,
///         and how to recognise one built for THIS market rather than a sibling.
/// @dev A concrete instance supplies three getters -- `BORROWED`, `BORROWED_QUOTE` and
///      `BORROWED_QUOTE_KIND` -- and nothing else.
///
///      Structured differently from `script/WstGBP.s.sol`, which restates all fifteen getters in
///      each of its two concrete scripts and pins that they agree with a test. That duplication is
///      tolerable for one-line getters; it is not tolerable for `_assertOracleExtra`, where a
///      silent divergence between the oracle script's checks and the market script's is exactly the
///      bug the check exists to catch. So this states everything once.
abstract contract WstGBPFxScript is WsgemLlamalendScript, WstGBPFxConstants {
    // --- What a concrete instance must supply --------------------------------------------------
    //
    // `BORROWED()` too, though it cannot be restated as abstract here: the base gives it a body
    // (the gem, for the same-currency case), and Solidity does not allow an implemented function to
    // be overridden by an unimplemented one. A concrete instance overrides the base's body
    // directly, and the hooks below dispatch to it virtually.

    /// @notice Where the borrowed token's dollar price comes from.
    function BORROWED_QUOTE() public pure virtual returns (address);

    /// @notice What shape that source has -- a WAD `price()` view, or a Chainlink round.
    function BORROWED_QUOTE_KIND() public pure virtual returns (WsgemFxLlamalendOracle.QuoteKind);

    // --- The collateral and its sterling leg ---------------------------------------------------

    function WSGEM() public pure override returns (address) {
        return WSTGBP;
    }

    function GEM() public pure override returns (address) {
        return TGBP;
    }

    function FX_FEED() public pure returns (address) {
        return GBP_USD_FEED;
    }

    function MAX_FX_AGE() public pure returns (uint256) {
        return MAX_FX_AGE_WSTGBP_FX;
    }

    // --- Oracle shim and rate calculator -------------------------------------------------------

    function MAX_UPSIDE_SPEED() public pure override returns (uint256) {
        return MAX_UPSIDE_SPEED_WSTGBP_FX;
    }

    function RATE_INTERVALS() public pure override returns (uint256) {
        return RATE_INTERVALS_WSTGBP_FX;
    }

    function MAX_PUBLICATION_GAP() public pure override returns (uint256) {
        return MAX_PUBLICATION_GAP_WSTGBP_FX;
    }

    function MIN_CHECKPOINT_SPACING() public pure override returns (uint256) {
        return MIN_CHECKPOINT_SPACING_WSTGBP_FX;
    }

    // --- Risk parameters -----------------------------------------------------------------------

    function A() public pure override returns (uint256) {
        return A_WSTGBP_FX;
    }

    function FEE() public pure override returns (uint256) {
        return FEE_WSTGBP_FX;
    }

    function LOAN_DISCOUNT() public pure override returns (uint256) {
        return LOAN_DISCOUNT_WSTGBP_FX;
    }

    function LIQUIDATION_DISCOUNT() public pure override returns (uint256) {
        return LIQUIDATION_DISCOUNT_WSTGBP_FX;
    }

    function SUPPLY_LIMIT() public pure override returns (uint256) {
        return SUPPLY_LIMIT_WSTGBP_FX;
    }

    // --- Monetary policy curve -------------------------------------------------------------------

    function TARGET_UTILIZATION() public pure override returns (uint256) {
        return TARGET_UTILIZATION_WSTGBP_FX;
    }

    function LOW_RATIO() public pure override returns (uint256) {
        return LOW_RATIO_WSTGBP_FX;
    }

    function HIGH_RATIO() public pure override returns (uint256) {
        return HIGH_RATIO_WSTGBP_FX;
    }

    function RATE_SHIFT() public pure override returns (uint256) {
        return RATE_SHIFT_WSTGBP_FX;
    }

    // --- Which oracle, and how to recognise it -------------------------------------------------

    function _deployOracle() internal virtual override returns (IWsgemShimOracle) {
        return IWsgemShimOracle(
            address(
                new WsgemFxLlamalendOracle(
                    IWsgem(WSGEM()),
                    BORROWED(),
                    IChainlinkAggregator(FX_FEED()),
                    BORROWED_QUOTE(),
                    BORROWED_QUOTE_KIND(),
                    MAX_UPSIDE_SPEED(),
                    MAX_FX_AGE()
                )
            )
        );
    }

    /// @dev The check the shared validation cannot make, and the reason it has to exist. Every
    ///      wstGBP instance -- the tGBP one and each of these -- shares a wsgem, a gem, a pip and
    ///      an upside speed, so ANY of their oracles passes every wiring assert in
    ///      `_assertOracle` while pricing collateral in a currency this market has no relationship
    ///      to. A live, healthy, self-consistent oracle for the wrong market is the one failure
    ///      nothing on-chain catches, and `WSGEM_ORACLE` is one paste away from it.
    ///
    ///      `BORROWED()` is the discriminator against the tGBP shim, which does not have it, so
    ///      the call reverts rather than returning something plausible. `BORROWED_QUOTE()` is the
    ///      discriminator between two cross-currency instances, which have identical everything
    ///      else.
    function _assertOracleExtra(IWsgemShimOracle oracle_) internal view virtual override {
        WsgemFxLlamalendOracle fx_ = WsgemFxLlamalendOracle(address(oracle_));

        require(fx_.BORROWED() == BORROWED(), "oracle: borrowed mismatch");
        require(address(fx_.FX_FEED()) == FX_FEED(), "oracle: fx feed mismatch");
        require(fx_.BORROWED_QUOTE() == BORROWED_QUOTE(), "oracle: borrowed quote mismatch");
        require(fx_.BORROWED_QUOTE_KIND() == BORROWED_QUOTE_KIND(), "oracle: borrowed quote kind mismatch");
        require(fx_.MAX_FX_AGE() == MAX_FX_AGE(), "oracle: fx staleness bound mismatch");

        // Redundant with `!frozen()` in the shared checks, and worth the gas anyway: this one names
        // which leg is dark instead of leaving an operator to work it out at broadcast time.
        require(!fx_.fxFrozen(), "oracle: conversion legs are unusable");
    }

    /// @dev The sibling asserts `price() == burncost()` for a freshly deployed oracle. Here the
    ///      reported price is the quote CONVERTED, so it equals `burncost()` only by coincidence.
    ///      The statement that survives the conversion is the one the sibling's check is really
    ///      making: a fresh oracle anchored itself one call ago, so the rate limit cannot be
    ///      binding against itself yet and the report must sit exactly on the undamped spot.
    function _assertFreshOracle(IWsgemShimOracle oracle_) internal view virtual override {
        require(oracle_.price() == oracle_.spotPrice(), "oracle: price != spot on a fresh deploy");
    }

    /// @dev The three terms behind the reported price, printed so an operator can check the
    ///      identity by hand against the feeds before broadcasting -- `quote x fx == spot`, up to a
    ///      wei of rounding. The same-currency instance needs none of this: there, `spot` IS the
    ///      wrapper's `burncost()` and the check is a single comparison.
    function _reportOracleExtra(IWsgemShimOracle oracle_) internal view virtual override {
        WsgemFxLlamalendOracle fx_ = WsgemFxLlamalendOracle(address(oracle_));

        console.log("  quote (gem/wsgem):", fx_.quotePrice());
        console.log("  fx rate (WAD) ...:", fx_.fxRate());
        console.log("  fx feed .........:", FX_FEED());
        console.log("  borrowed quote ..:", BORROWED_QUOTE());
        console.log("  max fx age ......:", MAX_FX_AGE());
        console.log("  CHECK: quote x fx / 1e18 == spot, and price == spot on a fresh deploy");
    }
}
