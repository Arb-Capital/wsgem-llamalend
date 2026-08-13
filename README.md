# wsgem → Curve Llamalend V2

Deploying Curve Llamalend V2 lending markets for a **wsgem** — an ERC-20 wrapper whose value
accrues against an underlying **gem** — with the wsgem as collateral, and either the gem or a
foreign stablecoin borrowed.

Llamalend will not take a wsgem as it stands. It needs a price oracle implementing
`price()`/`price_w()`, and a monetary policy bound to the market's own Controller. A wsgem provides
neither. This repo provides both, plus the deployment machinery and the runbook.

```
                     ┌─────────────────────────────────────────────┐
   wsgem feed        │                 this repo                   │
   (weekly NAV) ─────┼──► WsgemLlamalendOracle ──► price() ────────┼──► AMM
        │            │      ▲ same-currency: the gem is borrowed   │
        │            │                                             │
        │            │    WsgemFxLlamalendOracle ──► price() ──────┼──► AMM
        │            │      ▲ cross-currency: a dollar is borrowed │
   GBP/USD ──────────┼──────┘                                      │
   <borrowed>/USD ───┼──────┘                                      │
        │            │                                             │
        └────────────┼──► WsgemRateCalculator ──► rate() ──────────┼──► HyperbolicDynamicMP
                     └─────────────────────────────────────────────┘        (Curve's, vendored)
```

**Both shims are ownerless.** No owner, no ward, no setter, no upgrade path; every parameter
`immutable`. This is the design constraint, not a side effect — a wsgem's NAV is already a single
storage slot behind a single key, and interposing a second discretionary party between it and a
lending market adds something to trust rather than subtracting risk.

**Nothing in `src/` names a token.** Only the instance files under `script/` do. To list a future
wsgem, copy one, change the constants, done.

| Instance | Borrowed | Oracle | Sheet | Status |
|---|---|---|---|---|
| wstGBP / tGBP | the gem | `WsgemLlamalendOracle` | [wstgbp.md](docs/instances/wstgbp.md) | oracle live at [`0xdc85…557C`](https://etherscan.io/address/0xdc85a32D5B93e040A4e84401D567DcE02237557C) (2026-08-02), observing across a publication; market not yet deployed |
| wstGBP / crvUSD | crvUSD | `WsgemFxLlamalendOracle` | [wstgbp-crvusd.md](docs/instances/wstgbp-crvusd.md) | not deployed |

The first market borrows the wrapper's own gem, so `burncost()` — the WAD redemption quote — already
IS Llamalend's collateral-in-borrowed price and the shim carries no scaling term at all. The other
borrows a dollar against sterling collateral, which breaks that identity and needs a conversion:
`burncost x GBP/USD / <borrowed>/USD`. Hence a second oracle, not a second parameter.

## What's here

| | |
|---|---|
| `src/WsgemLlamalendOracle.sol` | Ownerless `price()`/`price_w()` shim, same-currency. Reports the redemption quote: rate-limits up, passes down, freezes on pause, floors a live zero quote at one wei. |
| `src/WsgemFxLlamalendOracle.sol` | Its cross-currency sibling. Same shim, one conversion later — and the rate limit binds on the NAV leg only, so a currency move reaches the market at full size. |
| `src/WsgemRateCalculator.sol` | Ownerless `rate()`/`rate_w()` shim. Realised yield across the last 4 publications. |
| `src/interfaces/` | Solidity translations of Curve's Vyper interfaces, plus the two feed shapes. |
| `script/WsgemLlamalendDeploy.s.sol` | Generic deploy bases. No token knowledge. |
| `script/WstGBP.s.sol` | The wstGBP/tGBP deployment. |
| `script/WstGBPFx.s.sol` | The shared base for cross-currency wstGBP instances. |
| `script/WstGBPCrvUSD.s.sol` | Three values: the borrowed token, its dollar quote, and that quote's shape. |
| `script/bytecode/` | Curve's `HyperbolicDynamicMP`, compiled, with provenance and two verification paths. |
| `docs/` | The runbook. Numbered, ordered, meant to be worked through. |
| `test/WsgemRateMath.t.sol` | Arithmetic hardening: an independent reference model, boundaries, saturation, ring indices. |
| `test/WsgemFxLlamalendOracle.t.sol` | The conversion: that the rate limit does not touch it, that each of its failure shapes freezes, and that composing cannot produce a zero. |
| `test/WstGBPCrvUSDDeployScript.t.sol` | One suite per instance. Its constants, its bounds, and that its deploy rejects every other instance's oracle. |
| `test/fork/` | The real gate: live feed, real `LendFactory`, real market creation — plus what a stepping publication actually costs, measured against a symmetrically damped counterfactual. |

## Quick start

```bash
make deps && make build
make test          # 296 unit + invariant tests, no RPC
make test-fork     # 62 tests against live mainnet state (needs ETH_RPC_URL)

make coverage      # first-party src coverage summary to the terminal
make gen-report    # + HTML report into docs/coverage-report/ (gitignored; needs lcov)

make oracle-dry    # simulate the oracle deploy against live state
make market-dry    # simulate the whole market deploy, every assert running

make market-dry INSTANCE=WstGBPCrvUSD   # the same, for another instance
```

Every deploy target takes `INSTANCE`, which names the file in `script/` and the two contracts inside
it; unset means wstGBP/tGBP, so nothing that predates it changes. Pass it as a command-line
assignment to `make`, not as an environment variable — the Makefile's `.env` include would win.

Deploy targets (`oracle-deploy`, `market-deploy`) sign from an encrypted keystore. Each has a
`-dry` twin that runs the same script keyless: no `--broadcast --verify`, no sender or keystore
flags, and wallet-resolving environment variables stripped — so simulated addresses will not
match a real deploy's.

## Docs

| | |
|---|---|
| [00-architecture.md](docs/00-architecture.md) | What a market is made of, the deployment cycle, who holds what power |
| [01-prerequisites.md](docs/01-prerequisites.md) | Toolchain, environment, pre-flight checks |
| [02-oracle-shim.md](docs/02-oracle-shim.md) | The four hazards, what is done about each, and the two more the conversion adds |
| [03-rate-calculator…](docs/03-rate-calculator-and-monetary-policy.md) | Why the long window, and Curve's policy |
| [04-parameters.md](docs/04-parameters.md) | Every number, its bounds, and why |
| [05-deploy-mainnet.md](docs/05-deploy-mainnet.md) | The runbook |
| [06-post-deployment.md](docs/06-post-deployment.md) | The DAO vote that actually opens the market |
| [07-operations.md](docs/07-operations.md) | Privileged surface, alarms, incident response |
| [08-integration.md](docs/08-integration.md) | For consumers of a deployed market |
| [reference/addresses.md](docs/reference/addresses.md) | Curve V2 infrastructure, the price feeds, and what was considered and rejected |
| [instances/](docs/instances/) | One sheet per market: [wstgbp](docs/instances/wstgbp.md), [wstgbp-crvusd](docs/instances/wstgbp-crvusd.md) |

## Two things to know up front

**Creating a market does not open one.** `LendFactory.create` is permissionless, but every market
it produces has `borrow_cap == 0` and nothing in this repo can change that — only a Curve DAO vote
calling `Configurator.set_borrow_cap`. That governance process is the slowest step and should be
started before you deploy, not after. [docs/06](docs/06-post-deployment.md)

**The NAV is published weekly by a permissioned key, and pausing publishes zero.** That single fact
drives most of the design. There is no meaningful on-chain staleness bound, because a six-day-old
price is normal operation. A zero must never reach Llamalend, so the oracle freezes at the last good
price instead. And because the yield tracks a policy rate that moves in steps, the rate calculator
is anchored on *publications* rather than on a clock — so its output is exactly constant between
them, and a rate change is tracked within a month rather than averaged against two months of stale
history. [docs/02](docs/02-oracle-shim.md),
[docs/03](docs/03-rate-calculator-and-monetary-policy.md)

**The oracle predicts nothing; the rate calculator does.** `price()` reports the wrapper's
redemption quote (`burncost`) capped by the rate limit — it can only ever under-report, never
over-report, so collateral is always valued at what redemption actually pays, or less. The one
wei-sized exception: a live feed quoting exactly zero is reported as one wei, since Llamalend
cannot accept zero. Only the borrow rate extrapolates, and only from realised growth.
Upward price moves are rate-limited to 0.25%/day at a measured cost of ~0.11 bp; downward moves
pass through in one block, deliberately and irreversibly.
[docs/02](docs/02-oracle-shim.md#what-the-limit-is-and-is-not-for)

## The monetary policy is Curve's, not ours

`HyperbolicDynamicMP` is Vyper 0.4.3 on Curve's module system, which Foundry cannot build without
the whole `vyper` + `curve_std` + `snekmate` toolchain. Reimplementing the rate curve in Solidity
would mean owning the maintenance and losing the audit, so the compiled artefact is vendored and
deployed with a plain `CREATE`.

That is only acceptable because it is verifiable, and it is — twice. Curve's own sDOLA/crvUSD
market runs the same contract, so a fork test deploys our bytecode with that market's constructor
arguments and asserts the runtime code is **byte-identical** to Curve's live deployment. A second
test does the same comparison locally against the compiled runtime, so a corrupted file fails
without needing an RPC. [script/bytecode/PROVENANCE.md](script/bytecode/PROVENANCE.md)

## Adding a new instance

1. Copy `docs/instances/TEMPLATE.md` to `docs/instances/<slug>.md`.
2. Copy `script/WstGBP.s.sol` to `script/<Symbol>.s.sol` and change the constants — or, for another
   dollar market against this collateral, copy `script/WstGBPCrvUSD.s.sol`, which is three values.
3. Add `test/<Symbol>DeployScript.t.sol` — one suite per instance — pinning the new constants and
   checking that the new deploy rejects every existing instance's oracle, and a
   `test/fork/<Symbol>.fork.t.sol` proving the addresses are what they claim to be.
4. Work the runbook with `INSTANCE=<Symbol>`.

If `docs/00`–`docs/08`, `src/`, or `script/WsgemLlamalendDeploy.s.sol` needs editing to accommodate
the new token, that is a bug in the generic layer — fix it there, generically, rather than forking.

## Licence

MIT. See [LICENSE](LICENSE).

## Dependencies

`forge-std` only, pinned to v1.16.2 in `foundry.lock`. No npm, no Node, no `--ffi`, and no Vyper
toolchain — the vendored bytecode is what removes that last one. Curve's contracts are reached by
address, not by import.
