# 3 — The rate calculator and the monetary policy

Two contracts sit between the wsgem's yield and what borrowers pay: `WsgemRateCalculator` (this
repo) and `HyperbolicDynamicMP` (Curve's, vendored as bytecode).

## Why a dynamic policy at all

In a like-kind market — the yield-bearing wrapper posted as collateral against its own underlying —
the borrow rate should track the collateral's yield. Otherwise the loop is either free money or
permanently uneconomic, and governance has to keep hand-correcting it. Curve built
`HyperbolicDynamicMP` for exactly this, and uses it for sDOLA/crvUSD and sfrxUSD/crvUSD.

It needs an external rate source:

```solidity
interface IRateCalculator {
    function rate()   external view returns (uint256);  // per second, x1e18
    function rate_w() external      returns (uint256);
}
```

No wsgem exposes one, so this repo provides it.

## The problem the calculator actually solves

A wsgem's NAV is **republished once a week**, and the yield it reflects tracks a central-bank
policy rate — so it is flat between publications and moves in steps, not a curve. Observed: about
**6.8 bp per week**, roughly 3.54% APR.

Measuring growth between arbitrary wall-clock samples — what an ERC-4626 rate calculator can do,
because its share price accrues every block — produces this:

```
  measured rate
       |
       |                    ^                   ^                   ^
       |                    |                   |                   |
     0 +--------------------+-------------------+-------------------+--
        |---- 6 days ------|                   publication
```

Zero for six days, an enormous spike on the seventh. The borrow rate would track the publication
schedule rather than the yield.

The fix is to anchor the measurement on **publications rather than on a clock**. A checkpoint is
recorded when the NAV *changes*, and the rate is the growth between two stored publications divided
by the time between them:

```
rate = (nav[k] / nav[k-4] - 1) / (t[k] - t[k-4])
```

Because a partial interval never enters the calculation, the reported value is **exactly constant**
between publications. Not approximately — `test_theReportedRateIsExactlyConstantBetweenPublications`
asserts equality on every intervening day.

### Why four intervals and not forty

A long window is not conservatism. It is lag.

The underlying yield steps when policy rates step, and one week does not predict the next. With a
trailing window of length W, a rate cut of D is followed by borrowers paying an average excess of
D/2 for the whole of W:

| Window | Excess after a 25 bp cut |
|---|---|
| 8 weeks | ~1.9 bp of debt (~8 bp of equity on a 5x loop) |
| 4 weeks | ~1.0 bp of debt |

Four intervals tracks a step change within a month while still dividing endpoint timing jitter by
four. A shorter window would be legitimate too — the sawtooth risk that would normally forbid it is
gone once the measurement is publication-anchored — but two intervals starts letting a single
anomalous publication set the borrow rate.

Systematic observation lag cancels entirely: if publications are consistently noticed a day late,
both endpoints shift equally and the span is unchanged.
`test_systematicObservationLagCancels` pins that.

### The minimum

No rate is reported until at least `MIN_INTERVALS` (2) publications have been seen. Below that the
estimate would rest on a single step, and one anomalous publication would set the borrow rate
outright.

This costs nothing in practice: a new market's borrow cap is zero until a DAO vote lifts it, so the
market is inert through exactly that period. `measurable()` and `intervalsMeasured()` report where
it stands.

### If publications stop

Between publications the reported rate is deliberately flat — that is the whole point. But a feed
that has stopped should not have its last reading held forever. Once it is overdue by more than
`MAX_PUBLICATION_GAP` (10 days, against a weekly cadence), the denominator starts growing with the
wall clock and the reported rate decays toward zero.

Inside the grace period the rate does not move at all, so a single late publication is absorbed
without disturbing borrowers. `overdue()` reports which side of it the feed is on.

## Every failure resolves to zero

Too few publications, a NAV that has not risen, a NAV that has fallen, a zero denominator, an
absurd numerator — all return 0. Never a revert: this contract is called from inside every borrow,
repay and liquidation, via `LendController.save_rate()`.

Zero is also the *safe* direction. Curve's policy floors it to `MIN_TARGET_RATE` (~1% APR). The
alternative — saturating high on garbage input — would let anyone able to move the feed drive the
borrow rate to the policy's ceiling.

The policy is defensive in the same direction: it reads the calculator through
`raw_call(..., revert_on_failure=False)` and clamps into `[317097920, 47564687975]`, about 1% to
150% APR. That clamp is a backstop, not this contract's error handling — but it does mean a
catastrophic NAV movement caps out at 150% APR rather than propagating.

A paused or unreadable feed is *not* an immediate zero: the ring still holds real, already-published
history, so the last measurement is held through the grace period and then decays. Zeroing the
borrow rate the instant a publication is late would be its own kind of wrong.

## `rate_w` is permissionless

Curve's note on `Controller._save_rate` says a stateful monetary policy must permission
`rate_write`. That applies to the policy, and Curve's policy does permission it. This calculator
sits one layer further out and is deliberately open, because there is nothing to gain by calling
it: a checkpoint is appended *only* when the NAV differs from the newest stored one, so no caller
can add a spurious entry or pack the ring to collapse the window. All a caller can influence is how
promptly a genuine publication is observed — and a systematic lag cancels between the endpoints.

## The monetary policy: `HyperbolicDynamicMP`

Curve's contract, deployed from vendored bytecode. Full provenance and the two verification paths
are in [`script/bytecode/PROVENANCE.md`](../script/bytecode/PROVENANCE.md); the short version is
that our compiled bytecode reproduces Curve's live sDOLA/crvUSD policy byte for byte, and a fork
test re-checks that on every run.

```
__init__(controller, rate_calculator, target_utilization, low_ratio, high_ratio, rate_shift)
```

The curve: the base rate is whatever the calculator reports, clamped. At `target_utilization` the
borrow rate equals that base rate; at 0% utilization it is `low_ratio ×` the base, at 100% it is
`high_ratio ×`. `rate_shift` adds a flat term.

| Parameter | Configured | Meaning |
|---|---|---|
| `target_utilization` | 0.90e18 | Borrow rate equals base rate at 90% utilization. |
| `low_ratio` | 0.5e18 | Half the base rate at 0% utilization. |
| `high_ratio` | 5e18 | Five times the base rate at 100% utilization. |
| `rate_shift` | 0 | No flat term. |

Same values Curve used for sDOLA/crvUSD. See [04-parameters.md](04-parameters.md).

### The controller cycle

The policy binds its Controller as an `immutable`, but the Controller is created by
`LendFactory.create`, which needs the policy. The cycle is broken by predicting the controller at
`CREATE(factory, nonce + 2)` — see [00-architecture.md](00-architecture.md). A wrong prediction
makes `create` revert; the deploy script also asserts it explicitly, and
`test_theControllerAddressPredictionHolds` proves it against the real factory on a fork.

### Changing it later

Only the Configurator's administrator can call `set_monetary_policy`, and the policy's own
`set_parameters` is gated on the factory admin. So the curve is DAO-adjustable after deployment,
but the *rate source* is not: `RATE_CALCULATOR` is immutable. Replacing the calculator means
deploying a new policy and a DAO vote to point the market at it.

## Reading it in operation

| View | On | Use |
|---|---|---|
| `rate()` / `apr()` | calculator | Measured wsgem yield. |
| `measurable()` / `intervalsMeasured()` | calculator | Whether enough publications have been seen. |
| `measuredSpan()` | calculator | The denominator in use. Constant between publications. |
| `overdue()` | calculator | True once the feed is past its grace period and the rate is decaying. |
| `oldestCheckpoint()` / `newestCheckpoint()` | calculator | The window's two ends. |
| `target_rate()` / `target_apr()` | policy | The base rate after clamping. |
| `rate()` | policy | The actual per-second borrow rate at current utilization. |
| `borrow_apr()` / `lend_apr()` | vault | What borrowers pay and lenders earn. |

`target_rate()` pinned at exactly `317097920` means the calculator is reporting zero and the policy
is on its floor. Before two publications have been seen that is expected; later it is an alarm.

A `measuredSpan()` that changes between publications would mean the feed is overdue — check
`overdue()`. In normal operation it is constant.
