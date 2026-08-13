# 4 — Parameters

Every number the deployment fixes, what bounds it, and why the configured value was chosen.

All of these live in `script/WstGBP.s.sol` — the one file in the repo that names a token — and
every one is asserted by `test/WsgemDeployScript.t.sol`, so none can move without the test suite
acknowledging it.

## What the chain enforces

Restated here because a violation reverts mid-broadcast with a bare Vyper assertion message.
`_preflight()` in the deploy script and `test_parametersSatisfyTheFactoryBounds` both check them
first.

| Constraint | Enforced by |
|---|---|
| `borrowed != collateral` | `LendFactory.create` |
| `2 <= A <= 10000` | `LendFactory.create` |
| `liquidation_discount > 0` | `LendFactory.create` |
| `loan_discount < 1e18` | `LendFactory.create` |
| `loan_discount > liquidation_discount` | `LendFactory.create` |
| `price() > 0` and `price_w() == price()` | `LendFactory.create` |
| `1e6 <= fee <= min(1e18 * 4 / A, 1e17)` | AMM constructor |
| `1e16 <= target_utilization <= 99e16` | `HyperbolicDynamicMP` |
| `low_ratio >= 1e16`, `high_ratio <= 100e18` | `HyperbolicDynamicMP` |
| curve must be solvable (`u_inf > 100%`) | `HyperbolicDynamicMP` |

## Market parameters

| Parameter | Value | Notes |
|---|---|---|
| `A` | 285 | Band width ≈ 1/A ≈ 35 bp. |
| `fee` | 0.002e18 (0.2%) | Ceiling at A=285 is ~1.40%. |
| `loan_discount` | 0.013e18 (1.3%) | Sets maximum LTV. |
| `liquidation_discount` | 0.01e18 (1%) | Sets the liquidation threshold. |
| `supply_limit` | `type(uint256).max` | Vault deposit cap. Not the borrow cap. |

**Where these come from.** Curve's sDOLA/crvUSD market — market 0 on the V2 mainnet factory — uses
exactly this set. It is the closest published analogue: a yield-bearing wrapper against a like-kind
asset, where the two prices track each other and the ratio drifts slowly in one direction.
The set has already been accepted by Curve's risk process for a comparable market.

**`A = 285` in words.** Bands are narrow, so soft liquidation converts collateral in small
increments and a borrower's loss during a slow drift is small. Narrow bands are appropriate
precisely because a wsgem/gem ratio does not gap — it steps upward by basis points. A market where
the ratio *could* gap would want a much lower `A`.

**`supply_limit` is not a risk control here.** Borrowing is gated by the borrow cap, which starts
at zero regardless of this value. See [06-post-deployment.md](06-post-deployment.md).

**Liquidator depth is not a variable here.** Redemption through the wrapper is atomic, against the
full supply, and slippage-free at the redemption bid — so a liquidator always has an exit at a known
price, however large the position. The oracle reports that bid (`burncost`), so the whole 100 bp
`liquidation_discount` is margin relative to the executable floor rather than partly consumed by
the exit spread. This differs from a market whose liquidation depends on pool depth.

**Still review before broadcast.** These came from a market with different collateral and a
different underlying. Check the interaction between the AMM `fee` and the band structure: LLAMMA's
soft liquidation depends on arbitrageurs trading against the AMM. Because the oracle prices at the
redemption quote, the exit spread is already in the price the AMM anchors to, and the
arbitrageur's edge is the AMM discount net of the 0.2% fee — the spread does not come out of it.

## Monetary policy curve

| Parameter | Value | Meaning |
|---|---|---|
| `target_utilization` | 0.90e18 | Borrow rate equals the measured yield at 90% utilization. |
| `low_ratio` | 0.5e18 | Half the base rate at 0% utilization. |
| `high_ratio` | 5e18 | Five times the base rate at 100% utilization. |
| `rate_shift` | 0 | No flat term. |

Also Curve's sDOLA/crvUSD set. The shape says: at the utilization the market is meant to sit at,
borrowers pay roughly what the collateral earns; below that it is cheaper, and the last 10% of
liquidity gets expensive enough to keep some withdrawable.

## Shim parameters

### `MAX_UPSIDE_SPEED` — 0.25% per day

`uint256(0.0025e18) / 1 days`. The maximum relative rise in reported collateral price per second.

Sized against the **observed** cadence, not a rule of thumb. The NAV rises about **6.8 bp per
week** (~3.54% APR), and the ceiling climbs ~1.04 bp/hour:

| | |
|---|---|
| One publication of yield (6.8 bp) | absorbed in ~6.5 hours |
| Mean under-report over a year of normal operation | **~0.11 bp** |
| A mistaken or hostile 2x publication | ~9 months to propagate |
| A 10x publication | ~2.5 years |

The 0.11 bp figure is measured, not claimed:
`test_aYearOfNormalOperationCostsAboutATenthOfABasisPoint` walks a year of the real cadence hour by
hour. Against a 100 bp liquidation discount, that is the entire cost of the limit.

**What it is not for.** It is not frontrunning protection — a 25 bp redemption spread already
dominates a 6.8 bp step, so nobody races a publication.

**Donation resistance comes for free, and is not why the number is what it is.** Curve's
post-sDOLA rule is that no Llamalend oracle should permit an instantaneous price jump *for any
reason, regardless of the technical design of the collateral*, and its recommendation list asks
specifically for "a per-block rate-of-change cap on vault PPS readings" — which is what this is.
The attack it was written against inflates the rate *upward*, so this speed sits on the exploited
direction rather than beside it: replayed on a fork, the same sequence nets an attacker +217 gem
with no cap and −41 gem with this one. It is nonetheless not *sized* for that. A wsgem has no
`convertToAssets` and no `totalAssets()` to donate into — the quote is a published number, not a
ratio over a balance — so sizing against the vector would mean sizing against nothing. See
[02-oracle-shim.md](02-oracle-shim.md#donation-attacks) for the mechanism and the full table.

**What it is for.** Bounding an erroneous or compromised publication, for the benefit of
Llamalend's lenders. The realistic failure is operational — a decimals slip or a units error in
whatever assembles the NAV off-chain — and those do not produce a 3 bp error, they produce a 100x
one. Without the limit that number is live in the AMM the next block and the vault's gem is
borrowable against fictitious collateral. With it, you get an alarm and roughly a day of slack to
set the borrow cap to zero, having lost 0.25%.

The limits of that: in a **key-compromise** scenario the wrapper itself is
already drainable, because redemption is atomic and against the full supply, so an attacker
publishing a high NAV redeems directly at the inflated bid. The rate limit protects the lending
market, not the asset. It is kept because Llamalend's lenders are a different set of people
holding a different asset — and because it costs 0.11 bp.

**It guards only the upside.** A mistaken publication *downward* reaches the market in one block and
liquidates positions irreversibly. That asymmetry is deliberate — a genuine collapse must reach the
market, and there is no independent price to appeal to, since redemption tracks the NAV down too —
but it is the sharper operational risk. See [07-operations.md](07-operations.md).

It is also measured. `test/fork/WsgemMarketLifecycle.fork.t.sol` runs the same book and the same
publication against this shim and against a symmetrically damped one; at the only step size where
anyone extracts anything, damping costs the borrower *more* (9 gem against 8) and delays
recognition by 29 days. The asymmetry is not a gap left open for want of a reason.

Rule for a different wsgem: pick the speed so one publication interval of real yield is absorbed in
hours, not days, while a month of allowance stays far below an order-of-magnitude move.
`test_oracleSpeedIsAQuarterPercentPerDay` asserts both ends of that.

Hard ceiling in the contract: 100% per hour (`MAX_UPSIDE_SPEED_LIMIT`). Anything looser is not a
rate limit in any useful sense.

### `RATE_INTERVALS` — 4, `MAX_PUBLICATION_GAP` — 10 days, `MIN_CHECKPOINT_SPACING` — 1 day

The measurement is anchored on publications, not on a wall clock, so it spans a number of
*publications* rather than a number of days. Four is about a month.

Two constraints, pulling opposite ways:

- **Enough intervals** that one anomalous publication cannot set the borrow rate. Two is the
  contract's floor (`MIN_INTERVALS`); four gives real margin and divides endpoint timing jitter by
  four.
- **Few enough** that a policy-rate change reaches borrowers promptly. A longer window is not
  conservatism but lag — after a cut of D it keeps reporting the old yield, and borrowers pay an
  average excess of D/2 for the whole window.

| Window | Excess after a 25 bp cut |
|---|---|
| 8 intervals | ~1.9 bp of debt (~8 bp of equity on a 5x loop) |
| 4 intervals | ~1.0 bp of debt |

`MAX_PUBLICATION_GAP` is grace, not a deadline: inside it the reported rate does not move at all, so
one late publication disturbs nothing. Ten days against a weekly cadence tolerates a late
publication comfortably. Past it, the denominator grows with the wall clock and the reported rate
decays toward zero rather than being held on evidence that has stopped arriving.

`MIN_CHECKPOINT_SPACING` is insurance, not tuning: at the weekly cadence a one-day floor never
binds in steady operation (the suite pins exact agreement with an ungated calculator, and pins
the deploy ramp — a publication landing within a floor of deployment — as the one bounded,
self-healing exception), and if the feed ever moves to
continuous accrual it turns the window into a rolling four days of realised yield instead of
letting it collapse to the last few observations — no redeploy, no governance action. Pick it well
under the publication cadence and well under the grace; a day against a weekly cadence gives a 7×
margin on one side and 10× on the other.

Contract bounds: `INTERVALS` in [2, 7]; `MAX_PUBLICATION_GAP` in [1 day, 90 days];
`MIN_CHECKPOINT_SPACING` below the gap, zero allowed. The grace must exceed the publication
cadence, or an on-time feed reads as overdue, and the floor must sit well under the cadence, or it
defers genuine publications — `test_rateIntervalsAndGap` asserts both.

## The cross-currency instances

Everything above is the wstGBP/tGBP set. wstGBP/crvUSD carries a different one, and
the reason is not subtle: the sDOLA/crvUSD donor above is a pair of assets that track each other,
and these markets are sterling collateral against dollar debt. Thirty-five basis point bands against
a currency pair that moves a percent on an ordinary day would leave borrowers permanently in soft
liquidation.

The donor is Curve's **svZCHF/crvUSD** market (controller `0xFd85e847…`), which is the same shape
with the Swiss franc in place of sterling. See [reference/addresses.md](reference/addresses.md).

| Parameter | wstGBP/tGBP | wstGBP/crvUSD | Source |
|---|---|---|---|
| `A` | 285 (~35 bp) | **180** (~56 bp) | svZCHF/crvUSD |
| `fee` | 0.2% | **0.05%** | svZCHF/crvUSD |
| `loan_discount` | 1.3% | **5%** | svZCHF/crvUSD's 4.3% (pre-launch) + 70 bp — see below |
| `liquidation_discount` | 1% | **2.8%** | svZCHF/crvUSD, raised from the pre-launch 2.3% to match the donor's current value — see below |
| `MAX_FX_AGE` | n/a | **30 hours** | 24 h heartbeat + grace |
| Everything else | | unchanged | Same wsgem, same feed, same cadence |

The shim and calculator values are deliberately identical across all markets. The rate limit
binds on the NAV leg alone, and the NAV leg is the same wsgem publishing on the same weekly cadence
at the same ~6.8 basis points; nothing about which token is borrowed changes what a mistaken
publication looks like or how fast it should propagate.

### `loan_discount` — the 70 basis points that are ours

svZCHF/crvUSD's oracle composes Curve pool moving averages, which move with every trade. Ours
composes a Chainlink push feed, which moves only when a round fires — triggered at **0.15%** on
GBP/USD. In a calm market the reported sterling price therefore sits routinely around that far
behind the market, in either direction, with nothing having failed. Seventy basis points is roughly
four times that typical lag.

The threshold is a trigger and not a cap, so it is **not** a bound on how far behind the price can
be: a move that outruns a round leaves it further behind until the next one lands, by however much
the market travelled meanwhile. The buffer is sized against the ordinary case and deliberately not
against the fast one.

### The donor has since moved — how this set was reconciled

svZCHF/crvUSD opened for borrowing on 2026-08-12 and re-parameterized around that launch. As read
on-chain at block 25746831 (2026-08-13) its `loan_discount` is now **4.8%** and its
`liquidation_discount` **2.8%** — both were 4.3% / 2.3% when this repo copied the set, while `A` and
`fee` are unchanged. The donor is not auto-tracked, so the two discounts were reconciled deliberately:

- `loan_discount`: **left at 5%.** It is still above the donor's 4.8% (the margin is now +20 bp
  rather than the +70 bp it was against 4.3%), and the buffer argument above — paying for the
  Chainlink push feed's lag — is unchanged.
- `liquidation_discount`: **raised 2.3% → 2.8% to match the donor.** Leaving it at 2.3% would have
  put the more-volatile sterling pair on a *thinner* liquidation buffer than the franc market it was
  copied from, which inverts the premise of carrying a wider set at all. Matching restores the
  ordering: wider than wstGBP/tGBP, and no tighter than the donor.

Re-check both against the live donor once more immediately before the DAO cap vote.

Spent on `loan_discount` rather than `liquidation_discount` on purpose: that moves where a borrower
may **open** without moving where liquidation begins, so the buffer pays for the borrower's entry
rather than giving a soft-liquidating position more room to keep losing.

It does not cover an arbitrarily fast move. Nothing in a discount does; that is what the liquidation
discount and the borrow cap are for.

### `MAX_FX_AGE` — 30 hours

Every Chainlink leg used here is on a 24-hour heartbeat, so the bound is that plus six hours of
grace. It is sized off the heartbeat rather than off the deviation cadence deliberately: a quiet
currency legitimately produces nothing but heartbeat rounds, and a bound tight enough to notice that
would freeze the market every quiet weekend. (Checked: GBP/USD does publish through weekends, so no
market-hours carve-out is needed.)

Curve's crvUSD aggregator has no publication time and nothing to bound — it moves with trades. Only
its zero and unreadable cases are guarded.

### The borrow-rate anchor — a known mismatch, accepted

`WsgemRateCalculator` measures the collateral's realised NAV yield — a **sterling** yield, ~3.54%
APR — and `HyperbolicDynamicMP` takes it as the target borrow rate. Against tGBP debt that makes a
loop roughly break-even at target utilization, which is the whole logic of the design. Against
dollar debt it does not: dollar rates are not sterling rates, and the loop is a currency carry
trade.

It is reused anyway, unchanged, and that is a choice rather than an oversight. The alternative is
vendoring and byte-verifying a second Curve monetary policy — a large new burden for what is a
policy preference, and one that would break the property that all markets run identical
shim code with identical parameters. Note svZCHF/crvUSD does not use a yield-linked policy at all
(its `RATE_CALCULATOR()` reverts, and its `target_apr` is 5.28%), so there is no precedent pulling
the other way either. Worth revisiting before the DAO conversation; not worth blocking on.

### The post-sDOLA rule is not met by the conversion

`MAX_UPSIDE_SPEED` above is argued partly as donation resistance under Curve's blanket rule that no
Llamalend oracle should permit an instantaneous price jump for any reason. That argument covers the
NAV leg on these instances too — it is the same limit on the same feed — and does **not** cover the
conversion, which is deliberately unthrottled and moves in discrete Chainlink rounds. No step is
capped: the deviation threshold (0.15% GBP/USD) triggers rounds rather than
limiting them, so a fast market steps by several times the threshold and a freeze-and-recover
delivers the whole accumulated move at once. The reasoning, and why throttling it would
be worse, is in [02-oracle-shim.md](02-oracle-shim.md#where-the-rate-limit-binds--the-nav-leg-and-nowhere-else);
raise it in the governance conversation rather than letting a reviewer find it.

### What is not priced in

The gem is assumed to hold its peg to sterling. There is no tGBP/USD feed, so a tGBP depeg moves
collateral value by exactly the depeg with nothing noticing. No discount here is sized for it, and
the same-currency instance does not carry the risk at all.

The assumption has on-chain precedent: the Steakhouse-curated WETH/tGBP Morpho Blue market
(`0xa4942ce9…d309d0c`) prices tGBP with the **same** Chainlink GBP/USD feed used here
(`0x5c0A…d4b5` — see `script/WstGBPFx.s.sol`), sterling standing proxy for the token with the
depeg equally unpriced. Precedent does not shrink the exposure; it says the assumption is already
load-bearing in a live lending market, with real money accepting the same terms.

## Choosing for a new wsgem

| Parameter | How to decide |
|---|---|
| `A`, `fee` | Does the pair gap, or drift? Drifting pairs take a high `A`. |
| `loan_discount`, `liquidation_discount` | The spread on the guaranteed exit, plus margin. |
| `MAX_UPSIDE_SPEED` | One publication of yield absorbed in hours. Then two ceilings: the full `MAX_ELAPSED` bank — 7 idle days of allowance, 1.75% at the speed configured here — can be consumed in one block if spot is above the anchor, so size it against the discounts of the tightest market it serves; and a month of chasing a mistaken publication far below an order of magnitude. |
| `RATE_INTERVALS` | ≥ 2; more only buys jitter rejection, and costs lag after a rate change. |
| `MAX_PUBLICATION_GAP` | Comfortably above the publication cadence. |
| `MIN_CHECKPOINT_SPACING` | Well under the cadence and the grace. The window it implies under continuous accrual — `RATE_INTERVALS ×` this — should still be a measurement, not an instant. |
| MP curve | Where the market should sit, and how hard to defend the last of the liquidity. |

If a new wsgem cannot be expressed by overriding the getters in `WsgemLlamalendConfig`, that is a
gap in the generic base — fix it there rather than forking the script.
