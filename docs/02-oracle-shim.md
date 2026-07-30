# 2 — The oracle shim

`src/WsgemLlamalendOracle.sol`. Ownerless, immutable, ~1.5 KB of runtime.

## What Llamalend asks for

```solidity
function price()   external view returns (uint256);
function price_w() external      returns (uint256);
```

One unit of **collateral** priced in the **borrowed** token, times `1e18`, regardless of either
token's own decimals. For a wsgem collateral / gem borrowed market that is the wsgem's NAV, which
the feed already publishes in WAD — so with both tokens at 18 decimals the shim carries no scaling
term at all. The constructor asserts both decimals rather than assuming them; an 18/non-18 pair
needs a different contract, not a different constant.

## The constraint that is easiest to get wrong

`LendFactory.create` does this:

```python
p: uint256 = staticcall _price_oracle.price()
assert p > 0                                  # dev: price oracle returned zero
assert extcall _price_oracle.price_w() == p   # dev: price() and price_w() mismatch
```

An oracle whose write path advances state *before* returning — the obvious way to write an EMA —
returns a different number from the read path and fails market creation outright. Worse, if it
somehow got past creation, the AMM uses `price()` on view paths and `price_w()` on state-changing
ones, so the two disagreeing means the market quotes one price and settles at another.

This shim computes the reported price as a pure function of the stored checkpoint, and only
persists afterwards:

```
_price(spot) = spot == 0 ? cachedPrice : min(spot, ceiling(cachedPrice, elapsed))

price()   = _price(spot)
price_w() = p = _price(spot); persist; return p
```

so the two agree by construction. `invariant_priceAndPriceWAgree` asserts it across arbitrary
sequences, and `test_theFactoryPriceCheckPassesAgainstTheLiveFeed` runs the factory's exact check
against the live feed on a fork.

## The three hazards

### 1. A paused feed reads zero

The feed signals a pause by publishing zero. Zero must never reach Llamalend: the factory rejects
it at creation, and an AMM that sees a zero mid-market prices every position to nothing.

The shim returns the last good price instead. A reverting or short-returning feed — the same
failure with a different shape after a proxy upgrade — is folded into the same path.

**Why freeze rather than revert.** Reverting propagates into every AMM read, which means no
repayment and no liquidation for as long as the pause lasts, while bad debt accrues unliquidated.
Freezing keeps the market working on a slightly stale number. Neither is good; freezing does less
damage.

**Why there is no staleness bound.** A wsgem's NAV is published weekly, so a six-day-old price is
normal operation, not a fault. Any age check tight enough to catch an abandoned feed would also
fire every week — and the feed exposes no publication timestamp on-chain to check against anyway.
Staleness is an operational alarm, not an on-chain guard. See [07-operations.md](07-operations.md).

### 2. A single publication can move the NAV arbitrarily far

Upward moves are rate-limited to `MAX_UPSIDE_SPEED` per second, relative, measured from the last
reported price:

```
ceiling = cachedPrice * (1 + MAX_UPSIDE_SPEED * min(elapsed, MAX_ELAPSED))
reported = min(spot, ceiling)
```

At the configured 0.25% per day the ceiling climbs ~1.04 bp/hour, which against the observed
cadence reads as:

| Move | Time to fully reflect |
|---|---|
| A week of yield (6.8 bp, ~3.54% APR) | ~6.5 hours |
| A month of yield (~27 bp) | ~26 hours |
| A mistaken or hostile 2× publication | ~9 months |
| A 10× publication | ~2.5 years |

Measured cost over a year of that cadence: a mean under-report of **~0.11 bp**, against a 100 bp
liquidation discount. `test_aYearOfNormalOperationCostsAboutATenthOfABasisPoint` walks the year hour
by hour rather than asserting the figure.

That asymmetry is the entire point. The limit is invisible in normal operation and an effective
stop otherwise — and it does not *block* a genuine repricing, it delays one, leaving time to notice
and for the DAO to repoint the market's oracle if the move is not genuine.

### What the limit is, and is not, for

Worth stating precisely, because two plausible rationales do not apply here.

**Not frontrunning protection.** Redemption through the wrapper costs 25 bp, which dominates a
6.8 bp weekly step. There is nothing to gain by racing a publication.

**Not manipulation resistance in Curve's sense.** `ERC4626EMAWrapper` smooths because
`convertToAssets` is a ratio anyone can move with a donation in the same block. A published NAV is
not movable by anyone except the key that publishes it — there is no market in this price to
manipulate.

**What it is for: an erroneous or compromised publication, on behalf of Llamalend's lenders.** The
realistic failure is operational — a decimals slip or a units error in whatever assembles the NAV
off-chain — and those produce a 100× error, not a 3 bp one. Without the limit that number is live in
the AMM the next block. With it, extraction is capped at 0.25%/day, which is the window in which the
DAO can set the borrow cap to zero.

Its limits are worth being equally precise about. In a **key-compromise** scenario the wrapper is
already gone: redemption is atomic and against the full supply, so an attacker publishing a high NAV
redeems directly at the inflated bid, which is faster and larger than borrowing on Llamalend. The
limit protects the lending market, not the asset. It earns its place because Llamalend's lenders are
a different set of people holding a different asset, and because it costs 0.11 bp.

And it is **only half a guard**: a mistaken publication *downward* passes straight through and
liquidates positions irreversibly. See hazard 3 below for why that is nonetheless the right
default.

`MAX_ELAPSED` (7 days) caps how much allowance can accrue in one step. Without it, a market left
untouched for months would bank enough allowance for the next call to jump arbitrarily far — which
is exactly what the limit exists to prevent. `price_w` also refreshes its timestamp through a
freeze, so a pause cannot bank allowance either.

Nor can the limit be gamed by calling it often. The ratchet is simple within a step and compounds
across them, so hammering `price_w` approaches continuous compounding while one call a day is simple
interest — a gap bounded by `e^x` versus `1 + x`, under 1 bp over a day.
`test_frequentCallsBuyAlmostNoExtraAllowance` pins that, and
`test_aTenXPublicationStillTakesYearsUnderConstantCalling` re-derives the 2.5-year figure against a
caller polling four times a day rather than a lazy market.

### 3. A fall must not be hidden

Downward moves pass through immediately and reset the ceiling to the new lower level.
Under-valuing collateral is recoverable; over-valuing it behind a stale high price is how bad debt
is made.

There is also no independent price to appeal to. Redemption through the wrapper is at the NAV less
the spread, so when the NAV falls the collateral genuinely *is* worth less — holding a stale high
price would be valuing it above what anyone can realise for it. The cost of that choice is that a
mistaken downward publication liquidates positions in one block, irreversibly, and nothing in this
shim stops it. That is the sharpest edge in the system and belongs in any risk write-up.

## Why the linear cap rather than an EMA

Curve's own `price_oracles/v2/ERC4626EMAWrapper.vy` smooths the upside with an exponential moving
average. This shim uses the linear speed cap from Curve's earlier
`price_oracles/OracleVaultWrapper.vy` instead. Two reasons, both specific to a wsgem:

- **The NAV steps, it does not accrue.** Against a weekly step what you want is a stated bound —
  "at most 1% per day" — that can be checked against a published cadence. An EMA gives an
  asymptote, which is the right shape for something accruing continuously and the wrong shape for
  something that jumps.
- **It is exact integer arithmetic.** No `expWad`, no magic constants, nothing transcendental to
  audit in a contract whose whole job is to be boring.

The behaviour contract — dampen up, pass down, never report zero — is identical either way. The
deviation is called out in the contract's own natspec so it reads as a decision rather than an
oversight.

## Reading it in operation

| View | Use |
|---|---|
| `price()` | What the market sees. |
| `spotPrice()` | The raw feed reading, or 0 if paused or unreadable. |
| `priceCeiling()` | The highest `price_w` could report right now. |
| `frozen()` | True when the feed is unreadable and the price is held. |
| `cachedPrice` / `cachedTimestamp` | The checkpoint the limit is measured from. |

A persistent gap between `price()` and `spotPrice()` means the rate limit is binding. In ordinary
operation it should not be, so that gap is the alarm worth wiring up.

## Adding a new wsgem

Nothing in this contract is token-specific. A new instance is a new constructor call with a
different `wsgem` and, if its publication cadence differs, a different `MAX_UPSIDE_SPEED`. Pick the
speed so one publication interval of real yield is absorbed in hours rather than days, while a month
of allowance stays far below an order-of-magnitude move. `test_oracleSpeedIsAQuarterPercentPerDay`
asserts both ends of that, so a new instance has to restate them.
