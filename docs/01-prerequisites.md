# 1 — Prerequisites

Everything that has to be in place before [05-deploy-mainnet.md](05-deploy-mainnet.md).

## 1. Toolchain

| Tool | Minimum | Check | Used for |
|---|---|---|---|
| `forge` / `cast` | 1.7.1 | `forge --version` | Everything. Pinned in CI. |
| `git` | any | `git --version` | Submodules. |
| `make` | any | `make --version` | Every target in this repo. |
| `python3` | 3.8+ | `python3 --version` | Credential-safe RPC diagnostics; serving coverage reports. |
| `genhtml` (lcov) | any | `genhtml --version` | `make gen-report` only. `make coverage` needs just forge. |

`vyper` is **not** required. Curve's monetary policy ships as vendored bytecode — see
[`script/bytecode/PROVENANCE.md`](../script/bytecode/PROVENANCE.md). You only need a Vyper
toolchain if you are regenerating that artefact, and the reproduction recipe is in that file.

```bash
make deps && make build
```

## 2. Environment

Copy `.env.example` to `.env` (gitignored) and fill it in.

| Variable | Required for | Notes |
|---|---|---|
| `ETH_RPC_URL` | deploys, `make test-fork` | Must be **archive** — the fork suite pins a block. |
| `ETH_FORK_BLOCK` | `make test-fork` | Pinned so the RPC cache is reusable. Defaults to 25670300; must stay ≥ 25670242, the live oracle's deployment block. |
| `ETH_FROM` | deploys | The deployer address. |
| `ETH_KEYSTORE` | deploys | Path to an encrypted keystore JSON. |
| `ETHERSCAN_API_KEY` | `--verify` | |
| `ETH_PRIO_FEE` | deploys | Optional → `--priority-gas-price`. Omitted entirely when unset. |
| `ETH_GAS_PRICE` | deploys | Optional → `--with-gas-price` (max fee per gas). Omitted when unset. |
| `WSGEM_ORACLE` | market deploy | An already-deployed oracle to reuse. Leave unset to deploy fresh. Validated against the configured wsgem, gem, feed and speed before anything is broadcast. |

Write bare values — no quotes, no inline comments. The Makefile `include`s this file, and make is
not a dotenv parser: it keeps the quotes in `KEY="abc"`, keeps a trailing space before an inline
`# note`, and truncates at a `#` inside a value.

## 3. Keys

Deploys sign from an **encrypted keystore**, never a raw private key on a command line or in the
environment:

```bash
cast wallet import deployer --interactive   # or point ETH_KEYSTORE at an existing file
```

forge prompts for the password at broadcast time.

The deployer holds no ongoing authority. Neither shim has an owner, and the deployer has no
standing relationship with the market once `create` returns — market administration belongs to the
Curve DAO through the Configurator. A compromised deployer key after the fact costs its balance and
nothing else.

## 4. Confirm the wsgem before anything else

The deploy script checks all of this in `_preflight()`, but check it by hand first — a mismatch
here means the wrong constants are pinned in `script/WstGBP.s.sol`.

```bash
export ETH_RPC_URL=...
export WSGEM=0x57C3571f10767E49C9d7b60feb6c67804783B7aE
export GEM=0x27f6c8289550fCE67f6B50BeD1F519966aFE5287

cast call $WSGEM "gem()(address)"        --rpc-url $ETH_RPC_URL  # expect: $GEM
cast call $WSGEM "pip()(address)"        --rpc-url $ETH_RPC_URL  # the feed the shims will cache
cast call $WSGEM "decimals()(uint8)"     --rpc-url $ETH_RPC_URL  # expect: 18
cast call $GEM   "decimals()(uint8)"     --rpc-url $ETH_RPC_URL  # expect: 18
cast call $WSGEM "navprice()(uint256)"   --rpc-url $ETH_RPC_URL  # expect: non-zero
cast call $WSGEM "burncost()(uint256)"   --rpc-url $ETH_RPC_URL  # expect: non-zero, <= navprice
```

A zero `navprice` means the feed is paused. Both shims refuse to deploy against it, deliberately —
there would be no last-good price to freeze at, and `LendFactory.create` rejects a zero price
anyway. Wait for the next publication.

## 5. Confirm Curve's side

```bash
export FACTORY=0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd

cast call $FACTORY "version()(string)"       --rpc-url $ETH_RPC_URL  # expect: "2.0.0"
cast call $FACTORY "paused()(bool)"          --rpc-url $ETH_RPC_URL  # expect: false
cast call $FACTORY "market_count()(uint256)" --rpc-url $ETH_RPC_URL
cast call $FACTORY "admin()(address)"        --rpc-url $ETH_RPC_URL  # the DAO agent that must vote
```

Full address list in [reference/addresses.md](reference/addresses.md).

## 6. Run the suites

```bash
make test        # 296 unit + invariant tests, no RPC
make test-fork   # 62 fork tests against live mainnet state
make coverage    # first-party src coverage (excludes fork tests and the gas bench)
```

`make test-fork` hard-fails without a mainnet RPC rather than skipping. That is deliberate: a
"skip if no RPC" branch would turn a missing RPC into a green run and let a broken deploy script
pass unnoticed.

The fork suite is the real gate. It proves, against live state, that the oracle reads the feed
correctly, that the vendored policy bytecode reproduces Curve's own deployment byte for byte, that
the controller-address prediction holds against the real factory, that `create` succeeds with the
configured parameters, that a reused oracle wired to the wrong asset is rejected, and that borrowing
stays shut until the Configurator opens it.

## 7. Read before you start

- [00-architecture.md](00-architecture.md) — what is being deployed and who ends up holding power.
- [04-parameters.md](04-parameters.md) — every number and its rationale.
- [06-post-deployment.md](06-post-deployment.md) — read this first, not last. The market is
  inert until a Curve DAO vote lifts its borrow cap, and that governance process is the slowest
  step. Start it before you deploy, not after.

## Checklist

- [ ] `make deps && make build` clean
- [ ] `.env` filled in, `ETH_RPC_URL` points at an archive node
- [ ] Keystore imported, `ETH_FROM` matches it
- [ ] wsgem constants confirmed on-chain against `script/WstGBP.s.sol`
- [ ] `navprice()` non-zero
- [ ] `burncost()` non-zero and at or below `navprice()`
- [ ] Factory live, unpaused, version 2.0.0
- [ ] `make test` green
- [ ] `make test-fork` green
- [ ] Parameters in [04](04-parameters.md) reviewed, not just inherited
- [ ] Governance conversation for the borrow cap started

Next: [02-oracle-shim.md](02-oracle-shim.md), or straight to
[05-deploy-mainnet.md](05-deploy-mainnet.md).
