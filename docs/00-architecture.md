# 0 — Architecture

What a Curve Llamalend V2 market is made of, where the two shims in this repo fit, and who holds
what power over the result.

## What gets deployed

A Llamalend V2 market is a triplet, created in one call by `LendFactory.create`:

| Contract | Role |
|---|---|
| **Vault** | ERC-4626. Lenders deposit the borrowed token and receive shares. |
| **LendController** | Borrower and liquidator entry point. Holds debt, health, caps, fees. |
| **AMM (LLAMMA)** | Holds collateral in price bands and converts it gradually during soft liquidation. |

Three more contracts are required but not created by `create`:

| Contract | Who provides it |
|---|---|
| **Price oracle** | You. Must implement `price()` and `price_w()`. |
| **Monetary policy** | You. Must implement `rate()` and `rate_write()`. |
| **Configurator** | Curve. One shared, permissioned instance per chain. |

A wsgem satisfies neither of the first two, which is why this repo exists.

```
                     ┌─────────────────────────────────────────────┐
   wsgem feed        │                 this repo                   │
   (weekly NAV) ─────┼──► WsgemLlamalendOracle ──► price() ────────┼──► AMM
        │            │      rate-limits up                         │
        │            │      passes down                            │
        │            │      freezes on zero                        │
        │            │                                             │
        └────────────┼──► WsgemRateCalculator ──► rate() ──────────┼──► HyperbolicDynamicMP
                     │      4-publication trailing yield           │        (Curve's, vendored)
                     └─────────────────────────────────────────────┘             │
                                                                                 ▼
                                                                          LendController
```

## The shims

Both are ownerless: no owner, no ward, no setter, no upgrade path, every parameter `immutable`. The
only mutable state in either is a checkpoint. This is the design constraint, not an accident — a
wsgem's NAV is already a single storage slot behind a single key, and interposing a second
discretionary party between it and a lending market would add a second thing to trust rather than
subtract risk.

### `WsgemLlamalendOracle`

Reports the price of one wsgem in gem, WAD-scaled — which for an 18/18 pair is the NAV itself.
Three behaviours, each answering a specific hazard: upward moves are rate-limited, downward moves
pass through immediately, and a zero or unreadable feed freezes the last good price rather than
propagating a zero. See [02-oracle-shim.md](02-oracle-shim.md).

### `WsgemRateCalculator`

Reports the wsgem's realised yield as a per-second rate, which Curve's `HyperbolicDynamicMP` uses
as the base rate of its curve. Measured between *publications* rather than on a clock, across the
last four of them — because a wsgem's NAV steps once a week and one step does not predict the next.
See
[03-rate-calculator-and-monetary-policy.md](03-rate-calculator-and-monetary-policy.md).

## Deployment order, and the one awkward dependency

`HyperbolicDynamicMP` binds its Controller as an `immutable`. The Controller is created by
`LendFactory.create`. `create` requires the monetary policy address. That is a cycle.

It is broken by prediction. `create` deploys vault, then AMM, then controller as three consecutive
`CREATE`s from the factory, so the controller lands at `CREATE(factory, nonce + 2)`. The policy's
constructor only stores the address — it never calls it — so a predicted address is safe, and a
wrong prediction makes `create` revert rather than silently produce a market wired to nothing.
Curve's own deployment scripts do exactly this.

```
1. WsgemLlamalendOracle          ← deployable and observable on its own, ahead of everything
2. WsgemRateCalculator
3. predict controller = CREATE(factory, nonce(factory) + 2)
4. HyperbolicDynamicMP(predicted, rateCalculator, curve…)
5. LendFactory.create(...)       ← permissionless
6. Curve DAO vote: Configurator.set_borrow_cap                    ← the market is inert until here
```

## A created market is not an open market

`create` is permissionless — anyone can call it. What it produces has `borrow_cap == 0`, and
nothing in this repo can change that. Only the Configurator's administrator, which on mainnet is
the Curve DAO, can lift it. Steps 1–5 are engineering; step 6 is governance, and it is the long
pole. See [06-post-deployment.md](06-post-deployment.md).

## Trust surface

Three parties, and it is worth being precise about which holds what.

**Curve DAO**, through the Configurator, over a live market:

| Call | Effect |
|---|---|
| `set_borrow_cap` | Opens or closes borrowing. |
| `set_price_oracle` | **Repoints the market away from this repo's shim**, subject to a max-deviation check. |
| `set_monetary_policy` | Replaces the rate curve. |
| `set_borrowing_discounts` | Moves LTV and the liquidation threshold. |
| `set_amm_fee` | Changes the AMM swap fee. |
| `set_admin_percentage` | Changes the DAO's share of interest. |

**wsgem governance**, over the feed the shims read: publish any NAV, or pause it by publishing
zero. The oracle bounds how fast a published number can raise reported collateral value, and never
lets a zero through — but it cannot manufacture a price the feed does not provide, and a downward
move is passed on immediately by design.

**This repo**: nothing. Neither shim has a privileged caller. `price_w()` and `rate_w()` are open,
which is safe because neither can be pushed past what the feed says — see the note on each in
[02](02-oracle-shim.md) and [03](03-rate-calculator-and-monetary-policy.md).

**Nobody** can change either shim's parameters, repoint its feed, or upgrade it. Replacing a shim
means deploying a new one and asking the DAO to repoint the market.

## Where to go next

| You want to | Read |
|---|---|
| Set up to deploy | [01-prerequisites.md](01-prerequisites.md) |
| Understand the oracle's behaviour | [02-oracle-shim.md](02-oracle-shim.md) |
| Understand the borrow rate | [03-rate-calculator-and-monetary-policy.md](03-rate-calculator-and-monetary-policy.md) |
| Choose or review parameters | [04-parameters.md](04-parameters.md) |
| Actually deploy | [05-deploy-mainnet.md](05-deploy-mainnet.md) |
| Open the market | [06-post-deployment.md](06-post-deployment.md) |
| Run it | [07-operations.md](07-operations.md) |
| Integrate against it | [08-integration.md](08-integration.md) |
