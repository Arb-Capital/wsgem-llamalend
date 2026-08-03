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
| Yield per publication | ~6.8 bp | |
| Redemption | atomic, full supply, no slippage, at NAV − 25 bp | |
| Feed key holder | 3-of-5 Safe `0xa73c94969dE90Edb159D29922C42fF24beDFA085` — holds both the poke key and the pip's admin functions (verified on-chain 2026-07-30: `getThreshold() == 3`, five owners, `pip.wards(safe) == 1`) | |
| Feed pause history | Never paused (as of 2026-07-30) | |
| Audit | [ProtoTech, 2026-04-29](https://docs.wstgbp.com/audits/2026-04-29-prototech-wstgbp-audit.pdf) | |

Confirmed on-chain at block 25647192: `wsgem.gem()` returns the gem above, both decimals are 18,
and `navprice()` was `1006710563072740256` (≈ 1.00671 gem per wsgem).

## What matters about the feed

Three properties drive nearly every design decision in this repo.

1. **The NAV is a single storage slot behind a single permissioned key.** No market sets it. In
   normal operation it only rises; a downward publication, a pause, or a zero redemption quote
   is a failure state, not routine.
2. **It is published weekly, tracks a central-bank policy rate, and steps rather than accruing.**
   So there is no meaningful on-chain staleness bound — a six-day-old price is normal — and a rate
   calculator measuring on a wall clock produces a sawtooth. Hence the freeze-on-zero behaviour in
   the oracle and the publication-anchored window in the calculator.
3. **Pausing publishes zero.** Which the oracle must never propagate, because
   `LendFactory.create` rejects a zero price and an AMM that sees one prices every position to
   nothing.

The feed sits behind an upgradeable proxy, so "unreadable" is as real a state as "paused". Both
shims treat a revert or a short return as a pause — and cap the gas they forward, so even a
hostile implementation cannot brick the read path.

**The same quorum holds both feed powers.** The 3-of-5 Safe above is both the publication key
and the pip's ward, so a publication and a proxy upgrade require the same three signatures. The
generic docs discuss the two capabilities separately.

## Parameters

| Parameter | Value | Why |
|---|---|---|
| `MAX_UPSIDE_SPEED` | 0.25% / day | The observed 6.8 bp step clears in ~6.5h at a measured cost of ~0.11 bp; a mistaken 10× takes ~2.5 years |
| `RATE_INTERVALS` | 4 | ~1 month. A policy-rate cut is tracked within four publications rather than averaged against eight |
| `MAX_PUBLICATION_GAP` | 10 days | Grace: one late publication moves the reported rate not at all |
| `MIN_CHECKPOINT_SPACING` | 1 day | Inert at the weekly cadence (7× margin). If the feed ever accrues continuously, the window becomes a rolling 4 days of realised yield — no redeploy |
| `A` | 285 | ~35 bp bands. The ratio drifts, it does not gap |
| `fee` | 0.2% | Ceiling at A=285 is ~1.40% |
| `loan_discount` | 1.3% | |
| `liquidation_discount` | 1% | Clears the 25 bp redemption spread four times over |
| `supply_limit` | unlimited | Not the borrow cap |
| `target_utilization` | 90% | |
| `low_ratio` / `high_ratio` / `rate_shift` | 0.5 / 5 / 0 | |

Inherited from Curve's sDOLA/crvUSD market — the closest published analogue, and a set Curve's own
risk process has already accepted. See [../04-parameters.md](../04-parameters.md). The liquidation
parameters should be reviewed rather than inherited unexamined: they came from a market with
different collateral and different liquidity.

## Deployed addresses

### Oracle — step 1 of [../05-deploy-mainnet.md](../05-deploy-mainnet.md)

| Contract | Address |
|---|---|
| `WsgemLlamalendOracle` | `0xdc85a32D5B93e040A4e84401D567DcE02237557C` |
| Deployed at block | 25670242 (2026-08-02), tx `0x8d9da787a890c46fe52024bc424c5f6893f945dedfe8b64ebdc9a2dde9b238dc`, 745,660 gas |
| Price at deployment | `1004861575533190669` (≈ 1.00486 gem/wsgem) — equalled the live `burncost()` exactly, per the fresh-oracle assert; post-broadcast readback confirmed `price() == spotPrice() == burncost()`, `frozen() == false`, wsgem/pip wiring correct |
| Observed across a publication | _(05 step 2 — in progress since 2026-08-02; do not skip)_ |

The live instance is under fork-test coverage:
[`test/fork/WstGBPLiveOracle.fork.t.sol`](../../test/fork/WstGBPLiveOracle.fork.t.sol) asserts its
wiring and the step-2 observation conditions at the pinned block, proves the deployed runtime code
is byte-identical to this tree's build, and drills a synthetic publication, a feed pause and a
100% spread against the deployed contract.

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

- **`price()` reports the redemption quote (`burncost`), not the NAV mid.** A liquidator exiting
  through redemption realises exactly the reported price, so the full 100 bp
  `liquidation_discount` is margin relative to the executable floor, and an arbitrageur trading
  against the AMM does not have the 25 bp exit spread eating their edge relative to the oracle —
  the spread is already in the price. The cost is 25 bp of borrowing power for every borrower,
  relative to a mid-based oracle. The wrapper's spread is technically adjustable (not intended to
  change in operation); the oracle reads the quote live, so a spread cut arrives rate-limited and
  a spread increase passes through immediately. At the settable maximum of 100% the quote is zero
  and the oracle reports one wei without anchoring it — see hazard 4 in
  [../02-oracle-shim.md](../02-oracle-shim.md).
- **Redemption is atomic, against the full supply, and slippage-free.** So liquidator depth is not a
  risk variable: an exit always exists at a known price, however large the position. This differs
  from a market whose liquidation depends on pool depth. The path has three gates, all open as
  configured on 2026-07-30: a compliance check (`canPass`, admitting arbitrary addresses as
  deployed), a burn window (`burnable()`, scheduled by the wrapper's `act`), and a settlement
  cooldown (zero, so redemption settles within the transaction). Payout is bounded by the
  wrapper's gem balance, which covered the full supply at the verification block. A closed burn
  window delays initiation, and the quote can move before it reopens — no price is locked until a
  redemption is initiated; a non-zero cooldown delays settlement of a claim whose amount is
  locked at initiation. The fork suite executes a redemption, confirms the payout equals
  `price()` per wsgem, and asserts the reserves cover a full-supply exit at the quote plus
  pending claims.
- **A downward NAV publication passes through immediately.** By design — see
  [../07-operations.md](../07-operations.md). It can move loans into liquidation within one
  block, irreversibly; the oracle does not limit downward moves.
- **Both tokens are 18 decimals**, which is what lets the oracle carry no scaling term at all.
