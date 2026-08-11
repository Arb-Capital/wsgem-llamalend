# 6 — Post-deployment

A created market is not an open market. Everything in
[05-deploy-mainnet.md](05-deploy-mainnet.md) is permissionless and produces a market with
`borrow_cap == 0`: lenders can deposit, nobody can borrow, and nothing in this repo can change
that.

Only the Curve DAO can. Start the governance conversation before you deploy — it is the slowest
step, measured in weeks.

**One vote per market.** wstGBP/tGBP, wstGBP/crvUSD and wstGBP/frxUSD each ship with
`borrow_cap == 0` and each needs its own `set_borrow_cap`. Opening one opens nothing else. The cap
is also the parameter that bounds what a mistaken publication or a currency shock can cost, so it
deserves a per-market number rather than a copied one — the cross-currency markets carry a risk the
first does not (see [04-parameters.md](04-parameters.md)).

## Step 1 — Pre-vote verification

Check these before proposing.

```bash
ID=$(cast call $FACTORY "vaults_index(address)(uint256)" $VAULT --rpc-url $ETH_RPC_URL)
cast call $FACTORY "markets(uint256)" $ID --rpc-url $ETH_RPC_URL
```

| Claim | How it is checked |
|---|---|
| The triplet is the factory's own | `markets(id)` returns your three addresses |
| Oracle is sane | `price()` == `price_w()`; `frozen()` and `quoteIsZero()` false. Same-currency: `price()` equals the live redemption quote (`burncost()`). Cross-currency: `price()` equals `spotPrice()`, and `fxFrozen()` is false |
| Oracle is ownerless | Verified source; no owner, ward or setter |
| Policy is Curve's own code | Runtime bytecode identical to Curve's live sDOLA policy — [PROVENANCE.md](../script/bytecode/PROVENANCE.md) |
| Policy is bound to this market | `MP.CONTROLLER()` == this controller |
| Rate calculator is ownerless | Verified source |
| Parameters are defensible | [04-parameters.md](04-parameters.md) |
| Fee receiver | `factory.fee_receiver(controller)` |
| The seed transient has left the window | `calc.checkpointCount() >= 6`, and `rate()` / `apr()` sane against the feed's ~3.54% APR — see below |

The seed row is time-gated where the others are static, and it is the enforcement of an ordering
[03](03-rate-calculator-and-monetary-policy.md) concedes nothing on-chain enforces: the
calculator's constructor seed is a mid-cycle observation — its NAV belongs to the previous
publication, its timestamp is the deploy block — so until it leaves the measurement window the
reported rate reads high by up to `INTERVALS/(INTERVALS−1)`, 4/3 here.
`test_theDeploySeedOverstatesEarlyAndCorrectsWhenItLeavesTheWindow` pins both the shape and the
exit: the **fifth** post-deploy publication pushes the seed out, so the gate is
`checkpointCount() >= 6` — generically `INTERVALS() + 2`: the seed, plus `INTERVALS` publications
to fill the window, plus one to evict the seed. (Reusing the formula at a different `INTERVALS`:
the count saturates at `SLOTS` = 8, so at the constructor maximum `INTERVALS = 7` the threshold is
unreachable and the count cannot witness the eviction — gate on `oldestCheckpoint()`'s timestamp
being later than the deploy block instead.) `intervalsMeasured() == 4` is **not** the gate; it
fills one publication earlier, while the seed is still the measured endpoint. Check the gate when
proposing and re-check before the vote executes: the cap must not go nonzero on a rate the seed is
still inflating.

## Step 2 — The vote

The vote must call the Configurator, from the factory's admin.

```
Configurator: 0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC

  set_borrow_cap(controller, <cap in gem units, 18 decimals>)
  set_admin_percentage(controller, <WAD share of interest to the DAO>)
```

`set_admin_percentage` is optional but conventional — Curve used `1e17` (10%) for its own reference
markets. `set_borrow_cap` is the one that matters: until it lands, the market is inert.

Confirm the admin the vote must execute from:

```bash
cast call $FACTORY "admin()(address)" --rpc-url $ETH_RPC_URL
cast call $CONFIGURATOR "default_admin()(address)" --rpc-url $ETH_RPC_URL
cast call $CONFIGURATOR "admins(address)(address)" $CONTROLLER --rpc-url $ETH_RPC_URL
```

**Ask for a small initial cap.** A cap can be raised by a later vote and lowered at any time; the
first one should be sized to what you are willing to lose while the market's real behaviour is
observed, not to the ambition for it. Curve's own reference markets launched capped. The cap is
also the standing mitigation for the two exposures the oracle deliberately leaves open — borrowing
stays live at the held price through a feed freeze, and up to seven idle days of banked ceiling
allowance (1.75%) can be consumed in one block if spot is above the anchor
([07-operations.md](07-operations.md)) — so a small first number is risk policy, not only launch
prudence. Raising it to a material number is the point at which wrapper solvency and — on the
cross-currency instances — the tGBP peg stop being observations and must be explicitly accepted
or mitigated; precedent documents those assumptions, it does not reduce them.

### What the proposal should say

The proposal should carry the reasoning as well as the addresses:

- The pair. wstGBP/tGBP is like-kind — the collateral wraps the borrowed token. The crvUSD and
  frxUSD instances are **not**: sterling collateral against dollar debt, with the carry and
  tGBP-depeg exposures of [04-parameters.md](04-parameters.md). Claim only what the instance
  being proposed supports.
- **The NAV is published weekly by a permissioned key and can be paused to zero.** This is the
  market's central risk. The mitigation is that the oracle bounds it — the reported price is the
  redemption quote (`burncost` — executable subject to the redemption gates below), up-moves
  rate-limited to 0.25%/day at a measured cost of ~0.11 bp, down-moves immediate, a pause freezes
  rather than zeroes. See
  [02-oracle-shim.md](02-oracle-shim.md). Say the downside plainly: a downward publication passes
  through in one block and can put loans into liquidation immediately and irreversibly —
  deliberate, because a genuine collapse must reach the market.
- **Redemption is atomic and slippage-free at the quote while its gates pass** — a compliance
  check, an open burn window, a zero settlement cooldown, all open as configured — and the payout
  is bounded by the wrapper's gem reserves, which covered the full supply at the verification
  block. Present those as the assumptions they are, not as guarantees: liquidator depth stops
  being a risk variable only while they hold, and wrapper solvency is what the exit rests on.
- Why the parameters, especially that `liquidation_discount` clears the redemption spread.
- That the monetary policy is Curve's own contract, with the bytecode argument.
- That both shims are ownerless, and that the DAO retains `set_price_oracle` if either misbehaves.

## Step 3 — Confirm execution

```bash
cast call $CONTROLLER "borrow_cap()(uint256)"        --rpc-url $ETH_RPC_URL
cast call $CONTROLLER "admin_percentage()(uint256)"  --rpc-url $ETH_RPC_URL
```

## Step 4 — Seed the vault

Borrowing needs lent liquidity. The vault is plain ERC-4626 over the gem:

```bash
cast send $GEM   "approve(address,uint256)" $VAULT <amount> --rpc-url $ETH_RPC_URL --keystore $ETH_KEYSTORE
cast send $VAULT "deposit(uint256,address)"  <amount> $ETH_FROM --rpc-url $ETH_RPC_URL --keystore $ETH_KEYSTORE
```

The vault carries 1000 virtual shares as inflation-attack defence, so a fresh vault does **not**
start at a 1:1 asset-to-share ratio. Use `convertToShares` / `convertToAssets`; do not assume.

## Step 5 — First loan, deliberately small

The first borrow is the real test of the whole stack. With an amount you are willing to lose:

```bash
cast call $CONTROLLER "max_borrowable(uint256,uint256,address)(uint256)" <collateral> <N> $ETH_FROM --rpc-url $ETH_RPC_URL
cast call $CONTROLLER "create_loan_health_preview(uint256,uint256,uint256,address,bool)(int256)" <collateral> <debt> <N> $ETH_FROM true --rpc-url $ETH_RPC_URL
```

then open it, check `health()`, and close it. Confirm along the way:

- `vault.borrow_apr()` and `lend_apr()` are sane.
- `MP.target_rate()` — expect exactly `317097920` until the rate calculator has recorded two
  publications. That is the floor, and correct at this stage.
- Repayment works. This is the path that a frozen oracle must keep open.

## Step 6 — Gauge and listing

Optional, and separable:

- Deploy a gauge over the vault's shares if lenders should earn CRV. Emissions then need their own
  DAO approval and ongoing gauge weight.
- Add the token icon to `curve-assets` if it is not already there.
- Wire up the monitoring in [07-operations.md](07-operations.md) **before** the cap is raised
  beyond the initial amount.

## Done when

- [ ] Vote passed and executed; `borrow_cap()` reads the intended value
- [ ] `admin_percentage()` as intended
- [ ] Vault seeded
- [ ] A loan opened, health checked, and **repaid**
- [ ] `borrow_apr()` / `lend_apr()` sane
- [ ] Monitoring live
- [ ] Addresses published in [instances/wstgbp.md](instances/wstgbp.md)
