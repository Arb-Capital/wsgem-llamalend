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
dominates a 6.8 bp step, so nobody races a publication. It is not manipulation resistance in
Curve's sense either: `ERC4626EMAWrapper` smooths because `convertToAssets` is a ratio anyone can
move with a donation in the same block, whereas a published NAV is not movable by anyone except the
key that publishes it.

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

Rule for a different wsgem: pick the speed so one publication interval of real yield is absorbed in
hours, not days, while a month of allowance stays far below an order-of-magnitude move.
`test_oracleSpeedIsAQuarterPercentPerDay` asserts both ends of that.

Hard ceiling in the contract: 100% per hour (`MAX_UPSIDE_SPEED_LIMIT`). Anything looser is not a
rate limit in any useful sense.

### `RATE_INTERVALS` — 4, and `MAX_PUBLICATION_GAP` — 10 days

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

Contract bounds: `INTERVALS` in [2, 7]; `MAX_PUBLICATION_GAP` in [1 day, 90 days]. The grace must
exceed the publication cadence, or an on-time feed reads as overdue —
`test_rateIntervalsAndGap` asserts that.

## Choosing for a new wsgem

| Parameter | How to decide |
|---|---|
| `A`, `fee` | Does the pair gap, or drift? Drifting pairs take a high `A`. |
| `loan_discount`, `liquidation_discount` | The spread on the guaranteed exit, plus margin. |
| `MAX_UPSIDE_SPEED` | One publication of yield absorbed in hours; a month of allowance far below 10%. |
| `RATE_INTERVALS` | ≥ 2; more only buys jitter rejection, and costs lag after a rate change. |
| `MAX_PUBLICATION_GAP` | Comfortably above the publication cadence. |
| MP curve | Where the market should sit, and how hard to defend the last of the liquidity. |

If a new wsgem cannot be expressed by overriding the getters in `WsgemLlamalendConfig`, that is a
gap in the generic base — fix it there rather than forking the script.
