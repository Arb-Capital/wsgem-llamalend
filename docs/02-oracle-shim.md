# 2 — The oracle shim

`src/WsgemLlamalendOracle.sol`. Ownerless, immutable, ~2.1 KB of runtime.

## What Llamalend asks for

```solidity
function price()   external view returns (uint256);
function price_w() external      returns (uint256);
```

One unit of **collateral** priced in the **borrowed** token, times `1e18`, regardless of either
token's own decimals. For a wsgem collateral / gem borrowed market that is the wsgem's redemption
quote — the wrapper's `burncost()`, the NAV net of the redemption spread, published in WAD. It is
the price at which an exit is actually executable, so collateral is never valued above what
redemption pays for it — with one wei-sized exception: a live feed quoting exactly zero is
reported as one wei, because Llamalend cannot accept zero (hazard 4 below). The quote is read
live on every call: the wrapper's spread is technically
adjustable (though not intended to change in operation), and a spread cut arrives as an ordinary
rate-limited rise while a spread increase passes through immediately, because the floor genuinely
dropped. With both tokens at 18 decimals the shim carries no scaling term at all. The constructor
asserts both decimals rather than assuming them; an 18/non-18 pair needs a different contract, not
a different constant.

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
_price(state, spot) = state == PAUSED    ? last report (anchor, or the one-wei floor)
                    : state == LIVE_ZERO ? 1 wei       (reported, never anchored)
                    :                      min(spot, ceiling(cachedPrice, elapsed))

price()   = _price(state, spot)
price_w() = p = _price(state, spot); persist; return p
```

so the two agree by construction. `invariant_priceAndPriceWAgree` asserts it across arbitrary
sequences, and `test_theFactoryPriceCheckPassesAgainstTheLiveFeed` runs the factory's exact check
against the live feed on a fork.

## The four hazards

### 1. A paused feed reads zero

The feed signals a pause by publishing zero. Zero must never reach Llamalend: the factory rejects
it at creation, and an AMM that sees a zero mid-market prices every position to nothing.

The shim returns the last good price instead. A reverting or short-returning feed — the same
failure with a different shape after a proxy upgrade — is folded into the same path. So is a feed
that tries to burn gas or return an oversized payload: the read forwards at most `PIP_READ_GAS`
(300k, more than an order of magnitude above the live quote's measured ~26.5k cost through the
wrapper's three-hop read) and copies exactly one
word back, so even a hostile proxy implementation cannot make `price()` revert with an
out-of-gas. An implementation that legitimately outgrows the cap reads as a pause, which
`frozen()` alarms.

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

### Donation attacks

Curve's position after the LlamaLend **sDOLA-long2** incident (2 March 2026) is a blanket one:

> LlamaLend price oracles should not have the potential for instantaneous price jumps for any
> reason, including the path involved here by donating to an ERC-4626 vault. Smoothing is required
> and should be standardized on all LlamaLend oracles, **regardless of the technical design of the
> collateral**.

That market's oracle, `CryptoFromPoolVaultWAgg`, applied an EMA to the pool's `price_oracle()` but
read `VAULT.convertToAssets(1e18)` instantaneously. 27 borrowers were hard-liquidated for ~822k
crvUSD of seized equity. The market predated Llamalend's oracle proxies and could not be repointed,
so it was deprecated rather than fixed.

**The mechanism is not the one intuition suggests, and getting it right matters here.** The rate was
inflated **upward** — 1.189 → 1.353, +13.79% — and it was the *rise* that liquidated the book. Two
steps, neither sufficient alone:

1. One permissionless `exchange()` dumped 13.25M crvUSD into the LLAMMA and bought 9.83M sDOLA out
   of every occupied band, leaving the bands holding crvUSD. That is soft-liquidation, performed
   deliberately and at a loss. On its own it liquidates nobody: health *improves*, because the
   bands now hold the borrowed asset.
2. `DolaSavings.stake(190_777e18, sDOLA)` — permissionless, staking on the vault's behalf, minting
   no shares — inflated `convertToAssets()`. On its own this liquidates nobody either: a higher
   collateral price is a healthier position.

Together they are lethal. `get_x_down` values a soft-liquidated band by asking what its crvUSD
would buy back at the current oracle, and that round trip carries `p_o` **cubed in the
denominator**. A 1.3% rate rise cost ~4 points of health; positions sitting on 0.3–0.8% margin went
straight under.

Note also *why* concentration mattered, because it is more specific than "a big market is a big
target". 87.9% of all sDOLA supply sat in the LLAMMA, so step 1 did double duty: it soft-liquidated
the book *and* handed the attacker nearly the entire supply. Redeeming it collapsed `totalSupply`
from 11.77M to 1.16M, which is what made a 190k DOLA donation move the rate 13.79% instead of
~1.6%. Supply capture shrank the denominator; the donation only had to be large relative to what
was left.

**The exploited direction is the direction this shim caps, and the vector is absent besides.**

1. **Upward moves are smoothed, at 0.25%/day.** Whatever moved the NAV and for whatever reason, the
   reported price cannot step. This is the property the rule asks for, and — given the mechanism
   above — it is aimed squarely at the half of the attack that does the damage. Curve's own
   recommendation list asks for exactly this alongside the EMA: *"add a per-block rate-of-change
   cap on vault PPS readings"*.
2. **There is additionally nothing to donate into.** [`IWsgem`](../src/interfaces/IWsgem.sol) is
   deliberately not ERC-4626: no `asset()`, no `convertToAssets`, no `totalAssets()`, no internal
   accounting of held assets at all. `burncost()` is `Act.burncost(Pip.read())` — a published
   number, not a ratio over a balance. There is no permissionless path to move it in either
   direction, so step 2 has no entry point at any price. The post-mortem draws the same line
   itself: *"This exploit only affects markets with vaults that can be inflated. For example,
   sfrxUSD and sreUSD are not vulnerable to a similar exploit."*

Point 2 is the stronger claim; point 1 is the one that survives being wrong about point 2.

**Measured, not argued.** `test/fork/WsgemMarketLifecycle.fork.t.sol` replays the attack in shape
against a real market on a fork — dump gem into the AMM to soft-liquidate the book, inflate the
rate 13.79%, then take every position that goes under — with the rate move handed to the attacker
**for free**, since modelling the donation would mean modelling a step a wsgem has no path to. What
is left is whether the remainder pays once its expensive half is removed:

| | attacker net | positions taken | oracle the AMM saw |
|---|---|---|---|
| No cap (the sDOLA oracle's behaviour) | **+217 gem** | 1 | 1.1434 — the full jump |
| Capped at 0.25%/day (shipped) | **−41 gem** | 0 | 1.0049 — unmoved |

The control arm has to reproduce the attack before the treatment is allowed to refute it, so it
asserts profitability rather than merely reporting it. Under the cap the attacker eats the cost of
step 1 and gets nothing for it.

**Where this deliberately diverges: the downside.** The rule is direction-blind; this shim is not.
A fall passes through in one block — see hazard 3 below for why, and
[07-operations.md](07-operations.md) for what it costs. That divergence is measured too, against a
symmetrically damped counterfactual (`test/mocks/DownsideDampedOracle.sol`) on the same book and
the same publication. At the only step size where anyone extracts anything — about −7%, under water
but still solvent — the borrower pays **8 gem** under pass-through and **9 gem** damped, the extra
being interest accrued over the 29 days the damped oracle takes to finish repricing. Damping did
not protect the borrower in any arm run. It delays recognition and charges them for the delay.

### What the limit is, and is not, for

One further rationale does not apply here.

**Not frontrunning protection.** Redemption through the wrapper costs 25 bp, which dominates a
6.8 bp weekly step. There is nothing to gain by racing a publication.

**What it is for: an erroneous or compromised publication, on behalf of Llamalend's lenders.** The
realistic failure is operational — a decimals slip or a units error in whatever assembles the NAV
off-chain — and those produce a 100× error, not a 3 bp one. Without the limit that number is live in
the AMM the next block. With it, extraction is capped at 0.25%/day, which is the window in which the
DAO can set the borrow cap to zero.

The limits: in a **key-compromise** scenario the limit does not protect the wrapper itself,
because redemption is atomic and against the full supply — an attacker publishing a high NAV
redeems directly at the inflated bid, which is faster and larger than borrowing on Llamalend. The
limit protects the lending market, not the asset. It is kept because Llamalend's lenders are a
different set of people holding a different asset, and because it costs 0.11 bp.

**The limit applies only upward**: a mistaken publication *downward* passes straight through and
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
Under-valuing collateral is recoverable; over-valuing it behind a stale high price creates bad
debt.

There is also no independent price to appeal to. Redemption through the wrapper is at the NAV less
the spread, so when the NAV falls the collateral genuinely *is* worth less — holding a stale high
price would be valuing it above what anyone can realise for it. The cost of that choice is that a
mistaken downward publication liquidates positions in one block, irreversibly; nothing in this
shim prevents that.

### 4. A live feed can quote zero

The wrapper's redemption spread is settable to 100%, which makes `burncost()` zero while the NAV
stays live. That is not a pause, and the shim does not freeze over it: freezing would hold the old
price while redemption pays nothing, keeping new borrowing open against collateral with no
executable value. The reported price drops to one wei instead — the smallest value Llamalend
accepts — which closes new borrowing. In normal operation this feed only rises; down, pause and
zero are all failure states, and this is the handling for the last of them.

The state is carried internally as a state, not as a reserved price value, so a genuine one-wei
quote remains an ordinary price. The floor report is never anchored: the rate-limit checkpoint
keeps the last real price, and when the spread is restored the report returns from that anchor —
downward immediately, upward to at most the anchor's own ceiling, in one block. That recovery is
the upside limit's **sole exception**, and it cannot raise the price above what the anchor's
ceiling already allowed; the limit's invariant is stated against the last *anchored* price for
exactly this reason. Entering and leaving the state emit `QuoteZeroed(anchor)` and
`QuoteRestored(price)`, once per transition. A pause that follows a witnessed zero quote keeps
holding the floor — a freeze preserves the last report, whatever it was. The pause signal is read
from the pip directly, separately from the quote, which is what makes the states distinguishable —
and deliberately so: a nonzero quote is *not* taken as proof the feed is live, because the quote's
last hop (`burncost()` is `Act.burncost(Pip.read())`) sits behind an upgradeable proxy of its own,
and a broken or hostile Act implementation could quote a price over a paused feed. Only the pip is
the pause authority. `quoteIsZero()` reports this state, `frozen()` the other, and `spotPrice()`
reads zero in both.

## Why the linear cap rather than an EMA

Curve's own `price_oracles/v2/ERC4626EMAWrapper.vy` smooths the upside with an exponential moving
average. This shim uses the linear speed cap from Curve's earlier
`price_oracles/OracleVaultWrapper.vy` instead. Two reasons, both specific to a wsgem:

- **The NAV steps, it does not accrue.** Against a weekly step what you want is a stated bound —
  "at most 0.25% per day", the configured value — that can be checked against a published cadence.
  An EMA gives an asymptote, which is the right shape for something accruing continuously and the
  wrong shape for something that jumps.
- **It is exact integer arithmetic.** No `expWad`, no magic constants, nothing transcendental to
  audit.

The behaviour contract — dampen up, pass down, never report zero — is identical either way. The
deviation is called out in the contract's own natspec so it reads as a decision rather than an
oversight.

This is a choice of **shape, not of strength**. Both satisfy "no instantaneous jumps"; they differ
in whether the bound is stated ("at most 0.25% per day") or asymptotic. Anything that reads the
linear cap as the weaker of the two has the comparison backwards: an EMA always moves some fraction
of the way toward a hostile reading immediately, where a speed cap moves a bounded amount and no
more. What the EMA buys instead is a smoother response to a feed that accrues continuously, which
is why it is the right default for an ERC-4626 wrapper and the wrong one here.

## Reading it in operation

| View | Use |
|---|---|
| `price()` | What the market sees. |
| `spotPrice()` | The raw redemption quote (saturated at 2^208−1), or 0 when paused, unreadable, or quoting zero — `frozen()` and `quoteIsZero()` tell those apart. |
| `priceCeiling()` | The highest `price_w` could report right now. |
| `frozen()` | True when the feed is paused or unreadable and the price is held. |
| `quoteIsZero()` | True when the feed is live but the quote is zero: the price is the one-wei floor. |
| `cachedPrice` / `cachedTimestamp` | The anchor and checkpoint time the limit is measured from. |

A persistent `price() < spotPrice()` means the rate limit is binding — that ordering is the exact
signal, since a pause and a live-zero quote both read `spotPrice() == 0` with the price above it.
In ordinary operation the limit should not bind, so that gap is the alarm to wire up.

## Adding a new wsgem

Nothing in this contract is token-specific. A new instance is a new constructor call with a
different `wsgem` and, if its publication cadence differs, a different `MAX_UPSIDE_SPEED`. Pick the
speed so one publication interval of real yield is absorbed in hours rather than days, while a month
of allowance stays far below an order-of-magnitude move. `test_oracleSpeedIsAQuarterPercentPerDay`
asserts both ends of that, so a new instance has to restate them.
