# Vendored bytecode: `HyperbolicDynamicMP`

Llamalend V2 requires a monetary policy contract, and the one this repo deploys is Curve's, not
ours. It is Vyper 0.4.3 built on Curve's module system, which a Foundry project cannot compile
without the whole `vyper` + `curve_std` + `snekmate` toolchain. Rather than reimplement the rate
curve in Solidity — inheriting the maintenance and losing the audit — the compiled artefact is
vendored here and deployed with a plain `CREATE`.

That trade only holds if the artefact is verifiable. It is, in two independent ways, both wired
into the test suite.

## What is here

| File | Bytes | keccak256 of the decoded bytecode |
|---|---|---|
| `HyperbolicDynamicMP.initcode.hex` | 6307 | `0x5650941c63a01ef085c4a0b8c477fbc75f1a4c1d985d1b5d55ed5c371c9ec0f9` |
| `HyperbolicDynamicMP.runtime.hex` | 4306 | `0xb27fc9e78d3b3c616627174768966702e745e501a4c8f42dc480b49c7818952e` |

Both are a single `0x`-prefixed hex string with **no trailing newline** — `vm.parseBytes` rejects
trailing whitespace. If you regenerate them, keep it that way.

The hashes are of the **decoded bytes**, not of the hex text: reproduce them with
`cast keccak $(cat <file>)`, which parses the `0x`-string into bytes before hashing.

The initcode is what `script/WsgemLlamalendDeploy.s.sol` deploys, with ABI-encoded constructor
arguments appended. The runtime file is the expected result, and exists so the equivalence check
can run without an RPC.

## Source

| | |
|---|---|
| Repository | `https://github.com/curvefi/curve-stablecoin` |
| Commit | `70716d6868642956fa7dfd56c100274148fb0150` (2026-07-27) |
| Path | `curve_stablecoin/mpolicies/v2/HyperbolicDynamicMP.vy` |
| Compiler | `vyper` 0.4.3 (`0.4.3+commit.bff19ea2`) |
| Dependencies | `snekmate` 0.1.2, `curve-std` @ `5556df1908837454c1b99d3cb79dd7e3d552d047` |

Constructor signature:

```
__init__(
    _controller: address,          # immutable; must be known before LendFactory.create runs
    _rate_calculator: address,     # immutable
    _target_utilization: uint256,
    _low_ratio: uint256,
    _high_ratio: uint256,
    _rate_shift: uint256,
)
```

## Reproducing it

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install "vyper==0.4.3" snekmate \
    "git+https://github.com/curvefi/curve-std@5556df1908837454c1b99d3cb79dd7e3d552d047"

git clone https://github.com/curvefi/curve-stablecoin.git && cd curve-stablecoin
git checkout 70716d6868642956fa7dfd56c100274148fb0150

vyper -p . -p "$VIRTUAL_ENV/lib/python3.10/site-packages" \
    -f bytecode         curve_stablecoin/mpolicies/v2/HyperbolicDynamicMP.vy
vyper -p . -p "$VIRTUAL_ENV/lib/python3.10/site-packages" \
    -f bytecode_runtime curve_stablecoin/mpolicies/v2/HyperbolicDynamicMP.vy
```

Strip the trailing newline from each and compare against the files here.

## Verification 1 — against Curve's own live deployment

The strongest check available, and it needs no trust in this document. Curve's sDOLA/crvUSD market
runs *this same contract*, deployed by Curve, at:

```
0xE02C02FCeeF5608762058bFe79BFb4064DcAA7b8
```

Vyper appends immutables to the end of the runtime code, so a matching build is not byte-identical
to a deployment — it is a byte-identical **prefix**, followed by that deployment's immutables. That
is exactly what is observed:

```
compiled runtime            4306 bytes
deployed runtime            4370 bytes
common prefix               4306 bytes   (the entire compiled runtime)
trailing 64 bytes = 2 immutable words:
  CONTROLLER       0xC77d97cF01737EB7aCE46cAb7cd9F60eC51a40c0
  RATE_CALCULATOR  0x2BC89Ef5Fa2916bB63960be90B4F224a148450b8
```

Both addresses match Curve's published deployment record for that market
(`deployments/mainnet/markets/llamalend-mainnet-sDOLA-crvUSD.jsonc`) — the sDOLA controller and the
`SDolaRateCalculator`. So the bytecode here is provably the contract Curve deployed, not merely
something that compiles from a URL.

`test/fork/WsgemMonetaryPolicyBytecode.fork.t.sol` reruns this comparison against live mainnet
state on every fork run.

## Verification 2 — locally, no RPC

`test/WsgemMonetaryPolicyBytecode.t.sol` deploys the initcode on the local VM and asserts the
resulting runtime code equals `HyperbolicDynamicMP.runtime.hex` plus the immutables it was given.
This catches a corrupted or truncated file without needing an RPC, so it runs in the default suite.

## If you change the pinned commit

Regenerate both files, update the table and the commit above, and re-run both tests. Do not update
one file without the other: the local check compares them to each other, and it will fail loudly
rather than silently deploying a mismatched pair.
