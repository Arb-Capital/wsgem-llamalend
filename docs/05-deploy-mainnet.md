# 5 — Deploying on mainnet

Two broadcasts, deliberately separated. Work through [01-prerequisites.md](01-prerequisites.md)
first.

```
                          ┌──────────────────────────────────────┐
  Step 1  oracle          │ WsgemLlamalendOracle       (tGBP)    │  make oracle-deploy
                          │  or WsgemFxLlamalendOracle (crvUSD,  │
                          │                             frxUSD)  │
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

## Step 0 — Choose the instance

Every target below is parameterised by `INSTANCE`, which names the file in `script/` and the two
contracts inside it. The default is the first instance, so a bare `make oracle-dry` still means
wstGBP/tGBP.

| `INSTANCE` | Market | Sheet |
|---|---|---|
| _(unset)_ or `WstGBP` | wstGBP / tGBP | [instances/wstgbp.md](instances/wstgbp.md) |
| `WstGBPCrvUSD` | wstGBP / crvUSD | [instances/wstgbp-crvusd.md](instances/wstgbp-crvusd.md) |
| `WstGBPFrxUSD` | wstGBP / frxUSD | [instances/wstgbp-frxusd.md](instances/wstgbp-frxusd.md) |

Pass it as a **command-line assignment to make** — `make market-dry INSTANCE=WstGBPCrvUSD`, not
`INSTANCE=WstGBPCrvUSD make market-dry`. The Makefile does `-include .env` and then `export`, which
makes every value in `.env` a make file-variable, and file-variables beat environment ones.

Each instance is deployed, observed and voted on **separately**. Nothing is shared between them
except the collateral and the wsgem's feed.

## Step 1 — Deploy the oracle

```bash
make oracle-dry      INSTANCE=$INSTANCE   # simulate against live state, no key, nothing sent
make oracle-deploy   INSTANCE=$INSTANCE   # broadcast + verify, signing from the keystore
```

Omit `INSTANCE=` only if you mean wstGBP/tGBP. It is shown on every command below because
forgetting it is silent: the default instance is a real, deployable market, so a bare
`make oracle-deploy` intended for wstGBP/crvUSD deploys a perfectly good wstGBP/tGBP oracle
instead.

`make oracle-deploy` refuses to run while `WSGEM_ORACLE` is set. That variable says an oracle
already exists, so a broadcast here would deploy a second one — most likely a `.env` prepared for
the market steps being replayed into step 1, which nothing in the script can catch (the oracle
script never reads the variable, and a duplicate oracle is a perfectly valid deployment). A
deliberate replacement is broadcast by blanking the variable on the command line —
`make oracle-deploy WSGEM_ORACLE= INSTANCE=…` — the one assignment that beats `.env`.

`make oracle-dry` runs the real script against live chain state with no wallet: it deploys into the
simulated EVM, runs every `_assertOracle` check, and prints the report block. Read every line of
that block against your instance's sheet in [instances/](instances/) before broadcasting.

**The one identity that holds for every instance is `price == spot`.** A fresh oracle checkpoints at
construction, so the rate limit cannot be binding against itself yet; anything else means the wrong
wsgem is configured. What `spot` itself should equal is what differs.

Same-currency (`INSTANCE` unset or `WstGBP`) — `spot` IS the wrapper's `burncost()`:

```
---
oracle ............: 0x…
  wsgem ...........: 0x57C3571f10767E49C9d7b60feb6c67804783B7aE
  gem .............: 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287
  borrowed ........: 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287   ← the gem again
  pip .............: 0x6A79dCe61A12aa4b75449e0B03746260765D07dF
  max upside/sec ..: 28935185185
  price ...........: <the live burncost, exactly>
  spot ............: <the same number>
---
```

`price` must equal `burncost()` exactly — the redemption quote, which sits 25 bp below `navprice()`
for this instance.

Cross-currency (`WstGBPCrvUSD`, `WstGBPFrxUSD`) — `spot` is the quote **converted**, so it equals
`burncost()` only by coincidence. The script prints the legs so the three-term identity can be
checked by hand:

```
---
oracle ............: 0x…
  wsgem ...........: 0x57C3571f10767E49C9d7b60feb6c67804783B7aE
  gem .............: 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287
  borrowed ........: <crvUSD or frxUSD -- NOT the gem>
  pip .............: 0x6A79dCe61A12aa4b75449e0B03746260765D07dF
  max upside/sec ..: 28935185185
  price ...........: <quote x fx / 1e18>
  spot ............: <the same number>
  quote (gem/wsgem): <the live burncost>
  fx rate (WAD) ...: <GBP per borrowed token>
  fx feed .........: 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5
  borrowed quote ..: <the Curve aggregator or the Chainlink feed>
  max fx age ......: 108000
  CHECK: quote x fx / 1e18 == spot, and price == spot on a fresh deploy
---
```

Record the address, then confirm on-chain. Common to both:

```bash
export ORACLE=<deployed address>
cast call $ORACLE "price()(uint256)"        --rpc-url $ETH_RPC_URL
cast call $ORACLE "spotPrice()(uint256)"    --rpc-url $ETH_RPC_URL   # must equal price()
cast call $ORACLE "frozen()(bool)"          --rpc-url $ETH_RPC_URL   # expect: false
cast call $ORACLE "WSGEM()(address)"        --rpc-url $ETH_RPC_URL
cast call $ORACLE "PIP()(address)"          --rpc-url $ETH_RPC_URL   # must equal wsgem.pip()
```

Same-currency only:

```bash
cast call $WSGEM  "burncost()(uint256)"     --rpc-url $ETH_RPC_URL   # must equal price()
```

Cross-currency only — `burncost()` is one leg, not the answer:

```bash
cast call $ORACLE "BORROWED()(address)"     --rpc-url $ETH_RPC_URL   # the dollar, not the gem
cast call $ORACLE "quotePrice()(uint256)"   --rpc-url $ETH_RPC_URL   # must equal wsgem.burncost()
cast call $ORACLE "fxRate()(uint256)"       --rpc-url $ETH_RPC_URL   # non-zero
cast call $ORACLE "fxFrozen()(bool)"        --rpc-url $ETH_RPC_URL   # expect: false
# and the identity, to a wei of rounding:
#   quotePrice() * fxRate() / 1e18 == spotPrice()
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

**Cross-currency instances: watch `quotePrice()`, not `spotPrice()`, for the publication itself.**
`spotPrice()` moves whenever the currency moves, which is most blocks, so it cannot tell you a
publication landed and it cannot tell you one was missed. `quotePrice()` is the NAV leg alone and
moves only when the wsgem's feed does. The table above still holds with that substitution in the
first row:

| | Expected |
|---|---|
| `quotePrice()` moves | at the publication, and only then |
| `price()` converges to `spotPrice()` | fully, before the next publication |
| `fxFrozen()` | stays false throughout |

**The absorption shape only happens if the checkpoint is warm.** The ceiling is measured from the
last `price_w`, and seven idle days bank the full 1.75% — which dwarfs a ~6.8 bp step, so a
publication landing on a cold checkpoint passes through in the first recorded call and the
hours-long absorption never occurs on-chain. That is exactly how the first live publication
recorded (2026-08-07 — [instances/wstgbp.md](instances/wstgbp.md)). To observe the middle rows of
the table live, poke `price_w` within a few hours before the expected publication.

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

### `WSGEM_ORACLE` serves every instance, and they are indistinguishable

One variable, three markets, and every wstGBP oracle shares a wsgem, a gem, a pip and an upside
speed — so the wrong one passes every wiring check the deploy scripts share while pricing collateral
in a currency the market has no relationship to. Nothing on-chain catches that.

What catches it is each instance's `_assertOracleExtra`, which states something true only of its own
oracle, and `make` echoes the pairing before every run:

```
using WSGEM_ORACLE=0x… for instance WstGBPCrvUSD
```

Read that line. If it names the wrong instance, the run reverts at the preflight — but read it
anyway.

## Step 3 — Create the market

```bash
export WSGEM_ORACLE=$ORACLE   # reuse the oracle from step 1 rather than deploying a second

make market-dry     INSTANCE=$INSTANCE   # simulate: calculator + policy + create, every assert running
make market-deploy  INSTANCE=$INSTANCE   # broadcast + verify
```

Rerun `make market-dry` — with the real `WSGEM_ORACLE` set — at a fresh block **immediately before
broadcasting**. The dry run executes the whole assert set against current chain state, and a
rehearsal from hours ago says nothing about the block you are about to broadcast into. An
oracle-less dry run remains a legitimate early rehearsal of the from-scratch pipeline; this one is
the preflight.

`--slow` is on in both deploy targets: each transaction must confirm before the next is sent,
because the controller-address prediction depends on the factory's nonce, and the policy has to
land before `create` references it.

An unset (or empty) `WSGEM_ORACLE` makes the script deploy a **fresh oracle in the same run** —
which is by definition an unobserved one. That is allowed only as a simulation: `make market-dry`
prints a reminder and rehearses the from-scratch pipeline, while a broadcast is refused twice
over — `make market-deploy` fails on a named check before building anything, and the script
itself reverts on any `--broadcast` without the variable, however it is invoked. The order is
not optional: the oracle exists and has been observed **before** the market is created on it.

Resuming a partial market broadcast is the one path the script cannot police: `--resume` replays
the saved transaction backlog without re-executing the script, so no Solidity check runs. Use
`make market-resume INSTANCE=$INSTANCE`, which re-applies the `WSGEM_ORACLE` guard before invoking forge — and never
call `forge script --resume` directly. (A backlog can only exist if the run that generated it
passed the guard, so this closes the loop rather than patching a live hole.)

If `WSGEM_ORACLE` is set, the script validates it **before broadcasting anything** — its wsgem,
gem, feed, configured speed, that it is not frozen, and that `price_w()` agrees with `price()`. That
check exists because `LendFactory.create` cannot do it: its only requirements are a non-zero price
and `price_w() == price()`, which a perfectly healthy oracle built for a *different* asset also
satisfies. The result would be a market pricing its collateral in terms of something unrelated, and
nothing on-chain would object. `test_anOracleForADifferentAssetIsRejected` demonstrates exactly that
oracle passing the factory's checks and being refused here.

Every instance adds its own check on top of that shared set, and needs to: the three wstGBP
instances share a wsgem, a gem, a pip and an upside speed, so the list above passes for **any** of
their oracles against **any** of their markets. `WSGEM_ORACLE` is one variable serving all three.
The cross-currency instances discriminate on `BORROWED()` and the feed addresses; the
same-currency one on the identity that its undamped spot IS `burncost()`, which a converted price
fails. The rejection is asserted in both directions, per instance, against mocks and against live
addresses.

What the script does, in order — the reasoning is in
[00-architecture.md](00-architecture.md#deployment-order-and-the-one-awkward-dependency):

1. Validate a supplied `WSGEM_ORACLE`, or deploy a fresh oracle — `WsgemLlamalendOracle` for the
   same-currency instance, `WsgemFxLlamalendOracle` for a cross-currency one. Which is decided by
   the instance's `_deployOracle`, not by anything you pass
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
borrowed ..........: <BORROWED() -- see below>
price .............: <see below>
measured yield/sec : 0
mp target rate/sec : 317097920
mp target apr .....: 10000000005120000
---
WARNING: borrow_cap is 0. …
```

`borrowed` and `price` are the two lines that differ by instance, and they are the two worth
reading hardest — a market created against the wrong one of either is not recoverable:

| Instance | `borrowed` | `price` |
|---|---|---|
| `WstGBP` | `0x27f6…5287` — tGBP, the gem | the live `burncost()` |
| `WstGBPCrvUSD` | `0xf939…1b4E` — crvUSD, **not** the gem | the composed price, `burncost x GBP/USD / crvUSD` |
| `WstGBPFrxUSD` | `0xCAcd…6E29` — frxUSD, **not** the gem | the composed price, `burncost x GBP/USD / frxUSD/USD` |

On a cross-currency instance `price` will sit meaningfully **above** `burncost()` — sterling buys
more than a dollar — and a `price` that happens to equal `burncost()` there means the wrong oracle
was supplied, not that everything lines up. Cross-check it against the step-1 report block for the
same oracle: the number should be unchanged apart from whatever the currency did since.

`measured yield/sec: 0` and `target apr: ~1%` are **correct** at this point, not a fault: the rate
calculator reports nothing until it has recorded two publications, so the policy sits on its
floor. See [03](03-rate-calculator-and-monetary-policy.md#the-minimum).

A nonce race — someone else creating a market on the factory while you deploy, so its nonce moves
and the controller lands somewhere other than predicted — surfaces in two different shapes
depending on when it happens. Caught during the simulation, it is the friendly one: the script
reverts with `controller address mispredicted` and nothing has been broadcast. But that assert
runs in the pre-broadcast simulation only. A race landing **between** simulation and broadcast
surfaces on-chain instead: `create` ends with the new controller calling the policy's
`rate_write()`, which the policy accepts only from the controller address baked into it at
deploy — now the wrong one — so the `create` transaction reverts `Controller only`, after the
calculator and the policy have already landed. The oracle (reused via `WSGEM_ORACLE`) is
unaffected, and re-running `make market-deploy` deploys a fresh calculator and policy anyway, so
the cost of the race is the gas of the dead pair — of which the policy is genuinely dead,
immutably bound to a controller that will never exist, and the calculator merely orphaned. Do
not try to salvage either into the re-run.

Submit the broadcast through a private RPC (e.g. Flashbots Protect). The pending `create` — and
the controller prediction it commits to — then never sits in the public mempool, which removes
the deliberate version of the race and leaves only the accidental one, in a window that is now
simulation-to-inclusion rather than simulation-to-public-visibility.

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
cast call $VAULT      "asset()(address)"                  --rpc-url $ETH_RPC_URL  # BORROWED()
cast call $AMM        "price_oracle_contract()(address)"  --rpc-url $ETH_RPC_URL  # our oracle
cast call $AMM        "admin()(address)"                  --rpc-url $ETH_RPC_URL  # the controller
cast call $CONTROLLER "monetary_policy()(address)"        --rpc-url $ETH_RPC_URL  # $MP
cast call $MP         "CONTROLLER()(address)"             --rpc-url $ETH_RPC_URL  # $CONTROLLER
cast call $MP         "RATE_CALCULATOR()(address)"        --rpc-url $ETH_RPC_URL  # our calculator

# Borrowing is shut
cast call $CONTROLLER "borrow_cap()(uint256)"             --rpc-url $ETH_RPC_URL  # expect: 0
```

`VAULT.asset()` is the token the market **borrows**, which is the gem only on the same-currency
instance. On a cross-currency one it must be `BORROWED()` — crvUSD or frxUSD — and reading the gem
back there means the wrong instance was deployed:

```bash
cast call $CONTROLLER "borrowed_token()(address)"         --rpc-url $ETH_RPC_URL  # == VAULT.asset()
cast call $CONTROLLER "collateral_token()(address)"       --rpc-url $ETH_RPC_URL  # the wsgem
```

Cross-currency instances, additionally — the oracle the market is actually wired to must be this
instance's, and the same-currency shim does not answer `BORROWED()` at all:

```bash
export ORACLE=$(cast call $AMM "price_oracle_contract()(address)" --rpc-url $ETH_RPC_URL)
cast call $ORACLE "BORROWED()(address)"        --rpc-url $ETH_RPC_URL  # == VAULT.asset()
cast call $ORACLE "BORROWED_QUOTE()(address)"  --rpc-url $ETH_RPC_URL  # the instance's dollar quote
cast call $ORACLE "fxFrozen()(bool)"           --rpc-url $ETH_RPC_URL  # expect: false
```

Verify the two shims on Etherscan — `--verify` does this, but confirm it landed. The monetary
policy will **not** verify through Etherscan's Solidity flow: it is Vyper deployed from raw
initcode. Point reviewers at
[`script/bytecode/PROVENANCE.md`](../script/bytecode/PROVENANCE.md) instead, which shows its
runtime code is byte-identical to Curve's own live deployment.

## Done when

- [ ] Oracle deployed, verified, address recorded
- [ ] Oracle observed across at least one publication, converging correctly
- [ ] Market created, all six addresses recorded in this instance's sheet under [instances/](instances/)
- [ ] `borrowed` and `price` in the step-3 report match the table for this instance
- [ ] Every readback in step 4 matches
- [ ] `borrow_cap()` reads 0 — confirming the market is not yet live
- [ ] Shims verified on Etherscan
- [ ] Broadcast artefacts committed from `broadcast/`

Next: [06-post-deployment.md](06-post-deployment.md) — the market does nothing until that is done.
