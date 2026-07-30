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
cast call $ORACLE "price()(uint256)"     --rpc-url $ETH_RPC_URL
cast call $ORACLE "spotPrice()(uint256)" --rpc-url $ETH_RPC_URL
cast call $ORACLE "frozen()(bool)"       --rpc-url $ETH_RPC_URL
```

| Alarm | Condition | Means |
|---|---|---|
| **Rate limit binding** | `price() < spotPrice()` for > 12h | A weekly step clears in ~6.5 hours, so 12h means either the yield outran `MAX_UPSIDE_SPEED` or someone published a jump. Investigate which. |
| **Feed frozen** | `frozen() == true` for > 1h | Feed paused or its proxy broken. Collateral is being valued on a held price. |
| **Publication missed** | Polled `spotPrice()` unchanged in > 9 days | Cadence is weekly. Nine days is late. There is no on-chain staleness guard — this alarm is the guard. |
| **NAV fell** | `spotPrice()` below its previous value | Passes straight through to collateral value. Check liquidation queue immediately. |

Key the publication alarm on **polling `spotPrice()`**, not on `PriceUpdated` events: the event
only fires when traffic drives `price_w`, so an idle market — including the entire
`borrow_cap == 0` period before the DAO vote — emits nothing however many publications land. The
same idleness also means nothing is checkpointing the rate calculator; that is harmless (both
shims read the live feed), but it is why the event stream goes quiet, not the feed.

`PriceUpdated(price, spot)` is emitted by `price_w` whenever the reported price moves, with the raw
spot alongside — so on a trafficked market the gap between the two is reconstructable from logs
alone.

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

## Incident response

### The feed is paused

The oracle freezes; the market keeps working on the last good price. The rate calculator holds its
last measurement through the grace period and then decays it. Borrowing, repayment and liquidation
all continue. Closing the market is not required: a zero borrow cap stops new borrowing, but
repayment and liquidation are the operations to keep open, and freezing already preserves both.

Watch for the pause outlasting a publication interval. Beyond that, collateral is being valued on a
number nobody is standing behind, and the question becomes whether the DAO should lower the borrow
cap to zero to stop new exposure accumulating.

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
