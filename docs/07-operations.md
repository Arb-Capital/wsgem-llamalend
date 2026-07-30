# 7 — Operations

## The complete privileged surface

Three parties. Nothing else can touch a deployed market.

### Curve DAO, through the Configurator

| Call | Effect | Risk |
|---|---|---|
| `set_price_oracle` | Repoints the market away from this repo's shim | **Critical** — bounded by a max-deviation check at the moment of the swap, not afterwards |
| `set_borrow_cap` | Opens or closes borrowing | High — a zero cap is the emergency stop |
| `set_monetary_policy` | Replaces the rate curve | Medium |
| `set_borrowing_discounts` | Moves LTV and liquidation threshold | High — can put live loans underwater |
| `set_amm_fee` | Changes the AMM swap fee | Low |
| `set_admin_percentage` | DAO's share of interest | Low |
| `set_custom_admin` | Delegates the above per-controller | **Critical** |

### wsgem governance, over the feed

| Action | Effect | What bounds it |
|---|---|---|
| Publish a higher NAV | Raises collateral value | Rate-limited to 0.25%/day by the oracle |
| Publish a lower NAV | Lowers collateral value | **Nothing** — passed through immediately, by design |
| Pause (publish zero) | Freezes the reported price | Oracle holds the last good value; market keeps working |
| Upgrade the feed's implementation | Arbitrary | Oracle treats a revert or short return as a pause |

A NAV published downward moves collateral value instantly and can put loans into liquidation. That
is deliberate — the alternative is holding a stale high price over collateral that has genuinely
lost value — but it is the sharpest edge in the system and belongs in any risk write-up.

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
| **Publication missed** | No `PriceUpdated` with a changed spot in > 9 days | Cadence is weekly. Nine days is late. There is no on-chain staleness guard — this alarm is the guard. |
| **NAV fell** | `spotPrice()` below its previous value | Passes straight through to collateral value. Check liquidation queue immediately. |

`PriceUpdated(price, spot)` is emitted by `price_w` whenever the reported price moves, with the raw
spot alongside — so the gap between the two is reconstructable from logs alone.

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

## Incident response

### The feed is paused

The oracle freezes; the market keeps working on the last good price. The rate calculator holds its
last measurement through the grace period and then decays it. Borrowing, repayment and liquidation
all continue. **Do not panic-close the market** — a zero borrow cap stops new borrowing
but repayment and liquidation are what you want to keep open, and freezing already preserves both.

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
questions are whether the collapse is *real* — a mistaken downward publication liquidates people
irreversibly and there is no undo — and whether the market should be capped to zero to stop new
borrowing against a falling asset.

This is the failure the oracle does **not** guard. If it happens and the publication turns out to
have been an error, the damage is already done.

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
