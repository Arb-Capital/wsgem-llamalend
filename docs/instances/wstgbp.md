# Instance: `wstGBP`

The first market. Collateral wstGBP, borrowed tGBP — the looping direction, where a borrower posts
the yield-bearing wrapper and borrows the underlying.

Script: [`script/WstGBP.s.sol`](../../script/WstGBP.s.sol) — the only file in the repo that names a
token.

## The token

| | Value | Runbook variable |
|---|---|---|
| wsgem (collateral) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` | `$WSGEM` |
| gem (borrowed) | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` | `$GEM` |
| Feed (`pip`) | `0x6A79dCe61A12aa4b75449e0B03746260765D07dF` | |
| wsgem decimals | 18 | |
| gem decimals | 18 | |
| NAV publication cadence | **weekly**, ~6.8 bp/step (~3.54% APR) | |
| Redemption | atomic, full supply, no slippage, at NAV − 25 bp | |

Confirmed on-chain at block 25647192: `wsgem.gem()` returns the gem above, both decimals are 18,
and `navprice()` was `1006710563072740256` (≈ 1.00671 gem per wsgem).

## What matters about the feed

Three properties drive nearly every design decision in this repo. State them plainly in any risk
write-up — reviewers will find them anyway.

1. **The NAV is a single storage slot behind a single permissioned key.** No market sets it.
2. **It is published weekly, tracks a central-bank policy rate, and steps rather than accruing.**
   So there is no meaningful on-chain staleness bound — a six-day-old price is normal — and a rate
   calculator measuring on a wall clock produces a sawtooth. Hence the freeze-on-zero behaviour in
   the oracle and the publication-anchored window in the calculator.
3. **Pausing publishes zero.** Which the oracle must never propagate, because
   `LendFactory.create` rejects a zero price and an AMM that sees one prices every position to
   nothing.

The feed sits behind an upgradeable proxy, so "unreadable" is as real a state as "paused". Both
shims treat a revert or a short return as a pause.

## Parameters

| Parameter | Value | Why |
|---|---|---|
| `MAX_UPSIDE_SPEED` | 0.25% / day | The observed 6.8 bp step clears in ~6.5h at a measured cost of ~0.11 bp; a mistaken 10× takes ~2.5 years |
| `RATE_INTERVALS` | 4 | ~1 month. A policy-rate cut is tracked within four publications rather than averaged against eight |
| `MAX_PUBLICATION_GAP` | 10 days | Grace: one late publication moves the reported rate not at all |
| `A` | 285 | ~35 bp bands. The ratio drifts, it does not gap |
| `fee` | 0.2% | Ceiling at A=285 is ~1.40% |
| `loan_discount` | 1.3% | |
| `liquidation_discount` | 1% | Clears the 25 bp redemption spread four times over |
| `supply_limit` | unlimited | Not the borrow cap |
| `target_utilization` | 90% | |
| `low_ratio` / `high_ratio` / `rate_shift` | 0.5 / 5 / 0 | |

Inherited from Curve's sDOLA/crvUSD market — the closest published analogue, and a set Curve's own
risk process has already accepted. See [../04-parameters.md](../04-parameters.md). The liquidation
parameters are the ones to argue rather than inherit: they came from a market with different
collateral and different liquidity.

## Deployed addresses

### Oracle — step 1 of [../05-deploy-mainnet.md](../05-deploy-mainnet.md)

| Contract | Address |
|---|---|
| `WsgemLlamalendOracle` | _(after 05 step 1)_ |
| Deployed at block | _(after 05 step 1)_ |
| Observed across a publication | _(05 step 2 — do not skip)_ |

### Market — step 3

| Contract | Address |
|---|---|
| `WsgemRateCalculator` | _(after 05 step 3)_ |
| `HyperbolicDynamicMP` | _(after 05 step 3)_ |
| Vault | _(after 05 step 3)_ |
| Controller | _(after 05 step 3)_ |
| AMM | _(after 05 step 3)_ |
| Factory market index | _(after 05 step 3)_ |

### Governance — [../06-post-deployment.md](../06-post-deployment.md)

| | Value |
|---|---|
| Vote ID | _(after 06 step 2)_ |
| Executed at block | |
| `borrow_cap` | _(0 until the vote executes)_ |
| `admin_percentage` | |

Curve infrastructure addresses are in [../reference/addresses.md](../reference/addresses.md) — they
are identical for every instance and are not repeated here.

## Simulation record

The full deploy has been simulated against live mainnet state (`make market-dry`), with every
post-deploy assertion passing. Expected gas: ~0.7 M for the oracle alone, ~22.9 M for the market
including the vault/controller/AMM triplet.

At creation the report reads `measured yield/sec: 0` and `mp target apr: ~1%`. That is correct, not
a fault: the rate calculator reports nothing until it has seen two publications, so the policy sits
on its floor through exactly the period during which the borrow cap is zero anyway.

## Instance-specific notes

- **`price()` reports the NAV mid, not the redemption bid.** A liquidator exiting through
  redemption realises 25 bp less than the reported price. That is 25 bp out of the 100 bp
  `liquidation_discount`, leaving 75 bp of real margin. Reporting `burncost` instead would move the
  same 25 bp from the discount into the price — explicit rather than implicit — at the cost of 25 bp
  of borrowing power for every borrower. The choice was to keep the borrowing power; either way it
  should be named in a risk review rather than discovered.
- **Redemption is atomic, against the full supply, and slippage-free.** So liquidator depth is not a
  risk variable: an exit always exists at a known price, however large the position. This is a
  materially stronger position than a market whose liquidation depends on pool depth, and it is
  worth stating explicitly in the governance proposal.
- **A downward NAV publication passes through immediately.** By design — see
  [../07-operations.md](../07-operations.md) — but it is the sharpest edge in the system: it can
  move loans into liquidation within one block, irreversibly, and the oracle does not guard it.
- **Both tokens are 18 decimals**, which is what lets the oracle carry no scaling term at all.
