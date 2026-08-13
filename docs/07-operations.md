# 7 — Operations

## The complete privileged surface

Three parties — plus any per-market administrator the DAO appoints via `set_custom_admin`, who
is then authorized for that market's per-market setters alongside the DAO.

### Curve DAO, through the Configurator

Per-market setters. Authorized callers: the default admin (the Curve DAO), or the market's
custom admin if one is set.

| Call | Effect | Risk |
|---|---|---|
| `set_price_oracle` | Repoints the market away from this repo's shim | **Critical** — bounded by a max-deviation check at the moment of the swap, not afterwards |
| `set_borrow_cap` | Opens or closes borrowing | High — a zero cap is the emergency stop |
| `set_monetary_policy` | Replaces the rate curve | Medium |
| `set_borrowing_discounts` | Moves LTV and liquidation threshold | High — can put live loans underwater |
| `set_amm_fee` | Changes the AMM swap fee | Low |
| `set_admin_percentage` | DAO's share of interest | Low |
| `set_callback` | Attaches a liquidity-mining callback to the AMM | Medium — the AMM invokes it with a plain external call inside deposits, withdrawals and exchanges, so a reverting callback blocks those operations until it is removed |
| `set_view` | Replaces the controller's view contract | Low — read path only; integrator previews route through it |

Default-admin-only:

| Call | Effect | Risk |
|---|---|---|
| `set_custom_admin` | Sets the market's custom-admin slot: that address becomes authorized for the per-market setters above, alongside the DAO | **Critical** — introduces a fourth principal for that market |
| `set_owner` | Replaces the Configurator's default admin, across all markets | **Critical** |

`set_custom_admin` was considered for these markets — a delegate able to zero a borrow cap without
a full DAO vote would shorten the [halt path](#halting-the-market) — and **not** used, recorded so
the question is not reopened without the reason: no comparable Curve market has one. Verified
on-chain 2026-08-11 at block 25732712: `admins()` is zero for sDOLA/crvUSD (`0xC77d…40c0`),
svZCHF/crvUSD (`0xFd85…F043`) and sfrxUSD/crvUSD (`0x3cD4…1bbe`), and `default_admin()` is the DAO
agent (`0x4090…9968`). A fourth principal is a fourth key to steward, the table's own risk column
calls the slot critical, and the ecosystem evidence says the DAO-only halt path is what comparable
markets actually live with.

### Curve DAO, as `factory.admin()`

A second admin slot, separate from the Configurator's `default_admin` — on mainnet both are the
same DAO agent (see [reference/addresses.md](reference/addresses.md)), but they are changed by
separate calls (`set_owner` on the Configurator, `transfer_ownership` on the factory).

| Call | On | Effect | Risk |
|---|---|---|---|
| `set_max_supply` | Vault | Caps or disables vault deposits (`maxSupply`) | Medium — zero stops new deposits; withdrawals are unaffected |
| `set_parameters` | Monetary policy | Rewrites the live rate curve (target utilization, low/high ratios, rate shift), within the constructor's bounds | Medium — the ~1%–150% APR clamp applies to the base rate only; `rate()` applies the ratios and shift on top of it, and the Controller caps what it charges at 300% APY (`MAX_RATE`) |
| `set_default_fee_receiver` / `set_custom_fee_receiver` | Factory | Redirects the admin share of interest | Low |
| `pause` / `unpause` | Factory | Stops or resumes new market creation | Low for a deployed market — existing markets are unaffected |
| `transfer_ownership` | Factory | Replaces `factory.admin()` — the principal for every row in this table | **Critical** |

### wsgem governance, over the feed

| Action | Effect | What bounds it |
|---|---|---|
| Publish a higher NAV | Raises collateral value | Rate-limited to 0.25%/day by the oracle |
| Publish a lower NAV | Lowers collateral value | **Nothing** — passed through immediately, by design |
| Pause (publish zero) | Freezes the reported price | Oracle holds the last good value; market keeps working |
| Upgrade the feed's implementation | Arbitrary | Oracle treats a revert or short return as a pause |

A NAV published downward moves collateral value instantly and can put loans into liquidation. That
is deliberate: the alternative is holding a stale high price over collateral that has genuinely
lost value.

### This repo

Nothing. Neither shim has a privileged caller, a setter or an upgrade path. Replacing one means
deploying a new one and a DAO vote to repoint the market.

## Monitoring

### The oracle is tracking the feed

```bash
cast call $ORACLE "price()(uint256)"           --rpc-url $ETH_RPC_URL
cast call $ORACLE "spotPrice()(uint256)"       --rpc-url $ETH_RPC_URL
cast call $ORACLE "frozen()(bool)"             --rpc-url $ETH_RPC_URL
cast call $ORACLE "cachedTimestamp()(uint40)"  --rpc-url $ETH_RPC_URL
```

| Alarm | Condition | Means |
|---|---|---|
| **Rate limit binding** | `price() < spotPrice()` for > 12h | A weekly step clears in ~6.5 hours, so 12h means either the yield outran `MAX_UPSIDE_SPEED` or someone published a jump. Investigate which. |
| **Allowance banking** | `cachedTimestamp()` more than 2 days old | Nothing is driving `price_w`, so ceiling allowance is banking toward the 7-day maximum of 1.75% — which the next write can consume in one block if spot is above the anchor by that much. At 0.25%/day, two idle days are 0.5%; **page before four** (1.0%, the entire same-currency liquidation discount). Per-market: the FX instances' wider discounts tolerate the full bank, the same-currency market's do not. The keeper below is the fix. |
| **Feed frozen** | `frozen() == true` for > 1h | Feed paused or its proxy broken. Collateral is being valued on a held price. |
| **Quote is zero** | `quoteIsZero() == true` | The wrapper's redemption spread reached 100%: redemption pays nothing and the reported price is one wei. Not a pause — new borrowing is closed and the last real anchor is kept for recovery. Escalate to the wrapper's operators. |
| **Publication missed** | Polled NAV-leg reading unchanged in > 9 days | Cadence is weekly. Nine days is late. There is no on-chain staleness guard — this alarm is the guard. |
| **NAV fell** | The NAV-leg reading below its previous value | Passes straight through to collateral value. Check liquidation queue immediately. |

**Which view is the "NAV-leg reading" depends on the instance, and getting it wrong breaks both of
the last two alarms.** On a same-currency oracle it is `spotPrice()`: the undamped price IS the
wsgem's redemption quote, so it moves only when the feed does.

On a cross-currency oracle it is **`quotePrice()`**. `spotPrice()` there is the quote already
multiplied by a currency rate that moves most blocks, which breaks the alarms in both directions:
a missed publication is masked, because sterling drifting keeps `spotPrice()` changing and the
9-day timer never fires; and an ordinary currency move against you reads as a NAV fall, so the
"check the liquidation queue immediately" page fires on days when nothing published at all.
`quotePrice()` is the NAV leg alone, in gem terms, and moves only when the wsgem's feed does.

```bash
# same-currency
cast call $ORACLE "spotPrice()(uint256)" --rpc-url $ETH_RPC_URL

# cross-currency -- the NAV leg, undamped, in GEM terms
cast call $ORACLE "quotePrice()(uint256)" --rpc-url $ETH_RPC_URL
```

Note `quotePrice()` reads zero when the wsgem's feed is paused or its quote is zero — the same two
states `spotPrice()` collapses on a same-currency oracle — and does NOT read zero merely because a
conversion leg is dark, which is what keeps the publication alarm alive through a Chainlink outage.
The **Rate limit binding** alarm above is unaffected: `price() < spotPrice()` compares two composed
numbers, and the conversion cancels.

Key the publication alarm on **polling**, not on `PriceUpdated` events: the event
only fires when traffic drives `price_w`, so an idle market — including the entire
`borrow_cap == 0` period before the DAO vote — emits nothing however many publications land. The
same idleness also means nothing is checkpointing the rate calculator; that is harmless (both
shims read the live feed), but it is why the event stream goes quiet, not the feed.

`PriceUpdated(price, spot)` is emitted by `price_w` whenever the anchored price moves, with the
raw spot alongside, and `QuoteZeroed(anchor)` / `QuoteRestored(price)` mark entry into and exit
from the one-wei zero-quote state — so on a trafficked market the full report history is
reconstructable from logs alone.

### The conversion legs are live — cross-currency instances only

The same-currency market has one feed to watch. The cross-currency ones have three, and each fails
differently.

```bash
cast call $ORACLE "fxFrozen()(bool)"    --rpc-url $ETH_RPC_URL   # a conversion leg is dark
cast call $ORACLE "quotePrice()(uint256)" --rpc-url $ETH_RPC_URL # the wsgem leg, gem terms
cast call $ORACLE "fxRate()(uint256)"   --rpc-url $ETH_RPC_URL   # the conversion factor, WAD
```

`frozen()` says the price is held; the pair above says which leg is responsible. `quotePrice() == 0`
with `fxRate() > 0` is the wsgem's own feed; the reverse is Chainlink or the aggregator. Alarm on
`fxFrozen()` separately from `frozen()`: the responses differ, and so does who you contact.

A stale conversion is the likeliest of the three to fire, because it is bounded by a clock
(`MAX_FX_AGE`, 30 hours) rather than by a publisher's intent. Chainlink's 24-hour heartbeat leaves
six hours of margin, so a fired alarm means the feed genuinely stopped rather than merely went
quiet.

### The borrow rate is being set by something real

```bash
cast call $CALC "rate()(uint256)"                --rpc-url $ETH_RPC_URL
cast call $CALC "apr()(uint256)"                 --rpc-url $ETH_RPC_URL
cast call $CALC "measurable()(bool)"             --rpc-url $ETH_RPC_URL
cast call $CALC "intervalsMeasured()(uint256)"   --rpc-url $ETH_RPC_URL
cast call $CALC "measuredSpan()(uint256)"        --rpc-url $ETH_RPC_URL
cast call $CALC "overdue()(bool)"                --rpc-url $ETH_RPC_URL
cast call $MP   "target_rate()(uint256)"         --rpc-url $ETH_RPC_URL
```

| Alarm | Condition | Means |
|---|---|---|
| **Policy on its floor** | `target_rate() == 317097920` and `measurable() == true` | The calculator is reporting zero with publications behind it: the NAV has not risen across the window, or the feed is unreadable. |
| **Policy on its ceiling** | `target_rate() == 47564687975` | A large NAV move is being read as yield. Almost certainly not real. |
| **Feed overdue** | `overdue() == true` | A publication is more than 10 days late. The reported rate has started decaying. |
| **Checkpoint missed** | `newestCheckpoint()` timestamp older than the last known publication | Nobody transacted, so `save_rate` never observed it. Call `rate_w()` directly to record it. |

`target_rate()` on the floor is **expected** until two publications have been recorded —
`measurable()` distinguishes that from a fault. `measuredSpan()` should be constant between
publications; if it is moving, the feed is overdue.

### Market health

Standard Llamalend surface: `total_debt()`, `borrow_cap()`, vault `totalAssets()` / `maxWithdraw()`
for utilization, `users_to_liquidate()` for the liquidation queue, `borrow_apr()` / `lend_apr()`.

### The administration has not moved

`Configurator.admins(controller)` is the market's custom-admin slot: zero means no delegate is
set; anything else is an address authorized for the per-market setters alongside the default
admin. Poll it together with `Configurator.default_admin()` and `factory.admin()`; a change to
any of the three changes who holds the levers above and should be tied to a known governance
action. The monetary policy's `parameters()` likewise reports the live rate curve, so a
`set_parameters` call is observable there.

## The keeper

Both shims are permissionless and both take no arguments. A daily poke of each is the whole job:

```bash
export WSGEM_CONTROLLER=<this market's controller>
make poke
```

`make poke` takes the **controller**, not the two shim addresses, and reads the oracle and the
calculator out of the market itself:

```
controller.amm().price_oracle_contract()        -> the oracle this market prices with
controller.monetary_policy().RATE_CALCULATOR()  -> the calculator this market rates with
```

That is not ceremony. Every wstGBP instance shares a wsgem, so a keeper handed two loose addresses
can pair one market's oracle with another's calculator, send two transactions, collect two green
receipts, and leave both markets' checkpoints exactly where they were — the failure this target
exists to prevent, in the shape a scheduled job would never notice. Deriving from the controller
removes the pairing as a thing anyone can get wrong. `WSGEM_ORACLE` and `WSGEM_CALC` are still
honoured if set, as assertions against what the market says, so a stale `.env` fails loudly.

Run one keeper per market. Nothing reverts without it — both views compute from live state — but
"nothing breaks" is only true of the contracts. The table below sizes the banked allowance against
each market's risk buffers, and for the same-currency market the full bank exceeds both of its
discounts: there the daily poke is a **launch requirement**, not an optimisation. Two things
improve with it, and one of them is a bound worth stating outright.

**`rate_w()`: observing publications on an idle market.** A checkpoint is only recorded when
something calls the calculator, so on a market with no traffic a publication can pass unobserved and
the measurement window falls behind the feed. This is the standing version of the **Checkpoint
missed** alarm above, which otherwise only gets noticed after the fact.

**`price_w()`: keeping the rate limit's banked allowance small.** The upside ceiling is measured
from the last `price_w`, capped at `MAX_ELAPSED` = 7 days, and it applies to whatever that oracle
anchors:

```
same-currency   ceiling = cachedPrice × (1 + MAX_UPSIDE_SPEED × min(elapsed, MAX_ELAPSED))
cross-currency  ceiling = cachedQuote × (1 + MAX_UPSIDE_SPEED × min(elapsed, MAX_ELAPSED))
```

The cross-currency anchor is the NAV leg in *gem* terms, not the reported price — which is why
`quoteCeiling()` is named for the quote and not the price. Conversion is linear in the quote, so
releasing an anchor 1.75% higher moves the reported price 1.75% higher at an unchanged conversion:
the banked allowance is the same size on both kinds of market. What differs is that currency
movement never *spends* it, so the NAV leg's worst case is bounded by idle time and by nothing else.

**The currency's own steps are a separate matter, and the poke does not touch them.** They are
deliberately unthrottled, and — apart from Curve's crvUSD aggregator, which does move with trades —
they are not continuous either: a Chainlink feed updates in discrete rounds, and an unthrottled
round steps the reported price the moment it lands.

**Nothing caps the size of that step.** A deviation threshold (0.15% on GBP/USD) is what
*triggers* a round, not a limit on how far the price has moved by the time one
lands — in a calm market steps arrive around the threshold, and in a fast one a single round can be
several times it, because the market keeps moving while the round is proposed, agreed and
transmitted. The unbounded case is starker still: if a leg halts past `MAX_FX_AGE` the oracle holds
its last price, and when a round finally lands the whole accumulated move arrives in one block. In
every case the oracle imposes no ceiling; the risk parameters and the borrow cap are what bound the
exposure.

So allowance accrues while nothing calls the write path. At the configured 0.25%/day — the same on
all instances — a full seven idle days bank **1.75%**, and the next `price_w` may report that
much higher in a single block. That is the one instantaneous **NAV-leg** jump this design still
permits — the currency steps above are independent of it, can coincide with it, and are not reduced
by poking — and it is worth sizing honestly against the parameters it lands on:

| Instance | liquidation discount | loan discount | band width | 1.75% is |
|---|---|---|---|---|
| wstGBP / tGBP | 1% | 1.3% | ~35 bp at A = 285 | **above both discounts**, 5.0 bands |
| wstGBP / crvUSD | 2.8% | 5% | ~56 bp at A = 180 | below both discounts, 3.1 bands |

The cross-currency market absorbs it more comfortably, which is worth stating because the intuition
runs the other way: it is the riskier market in almost every other respect, and this is the one
place its wider parameters — chosen for currency volatility, not for this — happen to help. It
does not make the poke optional there. Three bands is still three bands, and LLAMMA's band price
scales with the cube of the oracle price, so the AMM's internal price moves about **5.3%** on that
jump on every instance.

A daily poke reduces the worst case from 1.75% to **0.25%** — well under one band everywhere, 0.71
at A = 285 and 0.45 at A = 180. It costs one transaction a day, per market.

The window this matters most in is the one where nothing else is driving `price_w`: the entire
`borrow_cap == 0` period between market creation and the DAO vote — the same idleness the
publication alarm above is keyed around. Start the keeper at market creation, not at the vote.

Note the allowance cannot be gamed in the other direction either. Calling `price_w` *more* often
approaches continuous compounding against simple interest — a gap bounded by `e^x` versus `1 + x`,
under 1 bp over a day — so a keeper cannot ratchet the price up faster than a lazy market would.
`test_frequentCallsBuyAlmostNoExtraAllowance` pins that.

## Incident response

### A conversion leg goes dark — cross-currency instances only

The reported price freezes at its last good value and the market keeps working: repayment and
liquidation both run against a held price. That is the designed response and it needs no
intervention on a short outage.

What it costs is tracking. Collateral is valued at a stale currency rate for as long as the outage
lasts, in whichever direction the market has since moved. If it persists past a few hours, treat it
as a reason to ask the DAO for a `borrow_cap` reduction rather than as a reason to do nothing —
there is no way to repoint the feed, and no way to unfreeze it from this repo.

Note the crvUSD instance keeps a live borrowed-token quote from Curve through a Chainlink-wide
outage: its borrowed leg is Curve's aggregator, not a Chainlink feed, so only the sterling leg
can go stale.

### The feed is paused

The oracle freezes; the market keeps working on the last good price. The rate calculator holds its
last measurement through the grace period and then decays it. Borrowing, repayment and liquidation
all continue. Closing the market is not required: a zero borrow cap stops new borrowing, but
repayment and liquidation are the operations to keep open, and freezing already preserves both.

Be explicit about what "borrowing continues" includes: **`borrow_more` stays live at the held
price** for as long as the freeze lasts — the oracle freezes the price, not the market, and
`test_aMidLifeFreezeKeepsTheMarketServiceable` (`test/fork/WsgemMarketLifecycle.fork.t.sol`) pins a
mid-freeze borrow succeeding against the deployed stack. So a freeze alarm is not just a watch
item: it should immediately open the borrow-cap-to-zero conversation with the DAO, because the vote
takes days and new exposure accumulates at a price nobody is standing behind for all of them. Keep
a cap-to-zero vote pre-drafted, so the conversation starts at "execute?" rather than at "draft
one".

Watch for the pause outlasting a publication interval. Beyond that, the question is no longer
whether to propose the cap cut but whether it should already have executed.

### The feed publishes a jump

The oracle absorbs it at 0.25%/day, which is the window to act in. If the jump is not genuine, the
lever is `Configurator.set_price_oracle` — but note its max-deviation check is against the *current
reported* price, so repointing gets harder the longer the shim has been ratcheting toward the bad
number. Act early.

### The feed publishes a collapse

Passed through immediately — the oracle does not limit the downside, deliberately. Loans go into
soft and then hard liquidation within the block.

Liquidator depth is not the question: redemption through the wrapper is atomic, against the full
supply, and slippage-free at the redemption bid, so an exit always exists at a known price. The
questions are whether the collapse is *real* — a mistaken downward publication liquidates
positions irreversibly — and whether the market should be capped to zero to stop new borrowing
against a falling asset.

This is the failure the oracle does not guard: a liquidation caused by an erroneous publication
cannot be reversed.

### The oracle needs replacing

Deploy a new shim, verify it, and propose `set_price_oracle(controller, newOracle, maxDeviation)`.
The old one keeps reporting until the vote executes. Nothing in this repo can shortcut that, by
design.

### Halting the market

`set_borrow_cap(controller, 0)`. Stops new borrowing; leaves repayment and liquidation open. That
is the correct shape for an emergency stop — a halt that also blocked repayment would trap
borrowers in positions they were trying to unwind.

## Periodic review

| Cadence | Check |
|---|---|
| Weekly | Publication landed; oracle converged; no alarms |
| Monthly | `calc.apr()` against the wsgem's actual published yield, and against the policy rate it tracks |
| Monthly | Utilization against `target_utilization`; is 90% still the right target |
| Quarterly | Liquidation parameters against current liquidator depth |
| Quarterly | Borrow cap against actual demand and observed behaviour |
| On upstream change | Curve V2 upgrades, new Configurator powers, monetary policy revisions |
