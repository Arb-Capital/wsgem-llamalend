# 5 — Deploying on mainnet

Two broadcasts, deliberately separated. Work through [01-prerequisites.md](01-prerequisites.md)
first.

```
                          ┌──────────────────────────────────────┐
  Step 1  oracle          │ WsgemLlamalendOracle                 │  make oracle-deploy
                          └──────────────────────────────────────┘
                                        │
  Step 2  observe         ── at least one publication ──          (days, not minutes)
                                        │
                          ┌──────────────────────────────────────┐
  Step 3  market          │ WsgemRateCalculator                  │  make market-deploy
                          │ HyperbolicDynamicMP                  │
                          │ LendFactory.create → vault/ctrl/amm  │
                          └──────────────────────────────────────┘
                                        │
  Step 4  governance      ── Curve DAO vote: set_borrow_cap ──     docs/06
```

## Step 1 — Deploy the oracle

```bash
make oracle-dry      # simulate against live state, no key, nothing sent
make oracle-deploy   # broadcast + verify, signing from the keystore
```

`make oracle-dry` runs the real script against live chain state with no wallet: it deploys into the
simulated EVM, runs every `_assertOracle` check, and prints the report block. Read every line of
that block against [instances/wstgbp.md](instances/wstgbp.md) before broadcasting.

Expected report:

```
---
oracle ............: 0x…
  wsgem ...........: 0x57C3571f10767E49C9d7b60feb6c67804783B7aE
  gem .............: 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287
  pip .............: 0x6A79dCe61A12aa4b75449e0B03746260765D07dF
  max upside/sec ..: 28935185185
  price ...........: <the live burncost, exactly>
---
```

`price` must equal `burncost()` exactly — the redemption quote, which sits 25 bp below
`navprice()` for this instance. A fresh oracle checkpoints at construction, so the rate limit
cannot be binding against itself yet — anything else means the wrong wsgem is configured.

Record the address, then:

```bash
export ORACLE=<deployed address>
cast call $ORACLE "price()(uint256)"        --rpc-url $ETH_RPC_URL
cast call $ORACLE "spotPrice()(uint256)"    --rpc-url $ETH_RPC_URL   # must equal price()
cast call $WSGEM  "burncost()(uint256)"     --rpc-url $ETH_RPC_URL   # must equal price()
cast call $ORACLE "frozen()(bool)"          --rpc-url $ETH_RPC_URL   # expect: false
cast call $ORACLE "WSGEM()(address)"        --rpc-url $ETH_RPC_URL
cast call $ORACLE "PIP()(address)"          --rpc-url $ETH_RPC_URL   # must equal wsgem.pip()
```

## Step 2 — Watch it across a publication

Do not skip this step. The oracle is separable from the market so it can be observed before
anything depends on it, and the behaviour under observation — a NAV step being absorbed by the
rate limit — occurs on a weekly cadence. A market deployed the same afternoon has not observed
one.

Over at least one publication, confirm:

| | Expected |
|---|---|
| `spotPrice()` moves | at the publication |
| `price()` follows it | within a few hours, not instantly |
| `price()` converges to `spotPrice()` | fully, before the next publication |
| `frozen()` | stays false |
| `price()` | never zero, never above `spotPrice()` |

A `price()` that does *not* converge before the next publication means `MAX_UPSIDE_SPEED` is too
tight for this wsgem's actual yield — see [04-parameters.md](04-parameters.md). Redeploy the oracle
with a looser speed rather than proceeding; it is immutable, and it is far cheaper to replace now
than after a market points at it.

`make test-fork` complements this window: the live-instance suite
(`test/fork/WstGBPLiveOracle.fork.t.sol`) asserts the table's conditions against the deployed
oracle at the pinned block, proves its runtime code is byte-identical to what this tree compiles,
and drives it through a *synthetic* publication to demonstrate the absorption shape on demand.
It does not replace the observation — a real publication through the real feed key is the thing
being waited for — but it turns "watch it by hand" into something re-runnable.

## Step 3 — Create the market

```bash
export WSGEM_ORACLE=$ORACLE   # reuse the oracle from step 1 rather than deploying a second

make market-dry               # simulate: deploys calculator + policy, calls create, runs every assert
make market-deploy            # broadcast + verify
```

`--slow` is on in both deploy targets: each transaction must confirm before the next is sent,
because the controller-address prediction depends on the factory's nonce, and the policy has to
land before `create` references it.

An unset (or empty) `WSGEM_ORACLE` makes the script deploy a **fresh oracle in the same run** —
which is by definition an unobserved one. That is allowed only as a simulation: `make market-dry`
prints a reminder and rehearses the from-scratch pipeline, while a broadcast is refused twice
over — `make market-deploy` fails on a named check before building anything, and the script
itself reverts on any `--broadcast` (or `--resume`) without the variable, however it is invoked.
The order is not optional: the oracle exists and has been observed **before** the market is
created on it.

If `WSGEM_ORACLE` is set, the script validates it **before broadcasting anything** — its wsgem,
gem, feed, configured speed, that it is not frozen, and that `price_w()` agrees with `price()`. That
check exists because `LendFactory.create` cannot do it: its only requirements are a non-zero price
and `price_w() == price()`, which a perfectly healthy oracle built for a *different* asset also
satisfies. The result would be a market pricing its collateral in terms of something unrelated, and
nothing on-chain would object. `test_anOracleForADifferentAssetIsRejected` demonstrates exactly that
oracle passing the factory's checks and being refused here.

What the script does, in order — the reasoning is in
[00-architecture.md](00-architecture.md#deployment-order-and-the-one-awkward-dependency):

1. Validate a supplied `WSGEM_ORACLE`, or deploy a fresh `WsgemLlamalendOracle`
2. Deploy `WsgemRateCalculator`
3. Predict the controller at `CREATE(factory, nonce + 2)`
4. `CREATE` `HyperbolicDynamicMP` from the vendored initcode, bound to that prediction
5. `LendFactory.create(...)`
6. Assert the prediction held, re-assert the oracle, then assert the entire wiring

Expected report:

```
---
oracle ............: 0x…
rate calculator ...: 0x…
monetary policy ...: 0x…
vault .............: 0x…
controller ........: 0x…
amm ...............: 0x…
---
collateral ........: 0x57C3…B7aE
borrowed ..........: 0x27f6…5287
price .............: <the live burncost>
measured yield/sec : 0
mp target rate/sec : 317097920
mp target apr .....: 10000000005120000
---
WARNING: borrow_cap is 0. …
```

`measured yield/sec: 0` and `target apr: ~1%` are **correct** at this point, not a fault: the rate
calculator reports nothing until it has recorded two publications, so the policy sits on its
floor. See [03](03-rate-calculator-and-monetary-policy.md#the-minimum).

If the run reverts with `controller address mispredicted`, someone else created a market between
your simulation and your broadcast, moving the factory's nonce. Nothing is lost — the oracle and
calculator from the reverted run are still deployed and reusable. Re-run.

## Step 4 — Verify on-chain

Everything below is already asserted by `_assertMarket` — but note that forge runs the script
body, asserts included, in the **pre-broadcast simulation**: nothing re-checks the transactions
after they land. This readback against final chain state is the only post-broadcast
verification; record its output in the deployment record.

```bash
export FACTORY=0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd
export VAULT=<vault> CONTROLLER=<controller> AMM=<amm> MP=<monetary policy>

# The factory's own registry
ID=$(cast call $FACTORY "vaults_index(address)(uint256)" $VAULT --rpc-url $ETH_RPC_URL)
cast call $FACTORY "markets(uint256)" $ID --rpc-url $ETH_RPC_URL

# Wiring
cast call $VAULT      "asset()(address)"                  --rpc-url $ETH_RPC_URL  # the gem
cast call $AMM        "price_oracle_contract()(address)"  --rpc-url $ETH_RPC_URL  # our oracle
cast call $AMM        "admin()(address)"                  --rpc-url $ETH_RPC_URL  # the controller
cast call $CONTROLLER "monetary_policy()(address)"        --rpc-url $ETH_RPC_URL  # $MP
cast call $MP         "CONTROLLER()(address)"             --rpc-url $ETH_RPC_URL  # $CONTROLLER
cast call $MP         "RATE_CALCULATOR()(address)"        --rpc-url $ETH_RPC_URL  # our calculator

# Borrowing is shut
cast call $CONTROLLER "borrow_cap()(uint256)"             --rpc-url $ETH_RPC_URL  # expect: 0
```

Verify the two shims on Etherscan — `--verify` does this, but confirm it landed. The monetary
policy will **not** verify through Etherscan's Solidity flow: it is Vyper deployed from raw
initcode. Point reviewers at
[`script/bytecode/PROVENANCE.md`](../script/bytecode/PROVENANCE.md) instead, which shows its
runtime code is byte-identical to Curve's own live deployment.

## Done when

- [ ] Oracle deployed, verified, address recorded
- [ ] Oracle observed across at least one publication, converging correctly
- [ ] Market created, all six addresses recorded in [instances/wstgbp.md](instances/wstgbp.md)
- [ ] Every readback in step 4 matches
- [ ] `borrow_cap()` reads 0 — confirming the market is not yet live
- [ ] Shims verified on Etherscan
- [ ] Broadcast artefacts committed from `broadcast/`

Next: [06-post-deployment.md](06-post-deployment.md) — the market does nothing until that is done.
