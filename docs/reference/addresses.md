# Reference — addresses

Curve Llamalend V2 infrastructure. Identical for every wsgem instance; per-instance deployments are
recorded on the instance sheet in [`../instances/`](../instances/), not here.

## Ethereum mainnet — chain ID 1

| Contract | Address | Verified as |
|---|---|---|
| `LendFactory` | `0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd` | `version() == "2.0.0"` |
| `Configurator` | `0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC` | |
| Factory admin | `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` | `factory.admin()` — the DAO agent a vote must execute from |
| AMM blueprint | `0xc8AC252738E1Ece3f69CF77649C266c4E893cf41` | `factory.amm_blueprint()` |
| Controller blueprint | `0x47b6dF6494aD62474cDF365B90a56C648778A75d` | `factory.controller_blueprint()` |
| Vault blueprint | `0x2c3822264dcbd18d910C7834b1De8A70f368375b` | `factory.vault_blueprint()` |
| Controller view blueprint | `0x7259efD886e3A717a9206C604E0156E720871B2C` | `factory.controller_view_blueprint()` |
| Leverage zap | `0x5D847c892891B503c3483D3Abbc2a23774279b85` | |

The blueprints are read from the factory at creation time, not passed in, so they are informational
here — but worth recording, because a blueprint change means later markets are not the same code as
earlier ones.

Confirm before relying on any of it:

```bash
cast call $FACTORY "version()(string)"       --rpc-url $ETH_RPC_URL
cast call $FACTORY "paused()(bool)"          --rpc-url $ETH_RPC_URL
cast call $FACTORY "admin()(address)"        --rpc-url $ETH_RPC_URL
cast call $FACTORY "market_count()(uint256)" --rpc-url $ETH_RPC_URL
```

## Optimism — chain ID 10

| Contract | Address |
|---|---|
| `LendFactory` | `0x5F94073E3f51c1FFf92ffc6b4B06b7Af193B3640` |
| `Configurator` | `0xd36c590531cAF5F620C57Faf5827Ce8E7f6E5Bec` |

Untested by this repo. The shims are chain-agnostic, but nothing here has been run against
Optimism — treat a deployment there as new work, not a copy.

## Reference deployments worth comparing against

Curve's own V2 markets. The sDOLA one is the closest analogue to a wsgem market — a yield-bearing
wrapper against a like-kind asset — and this repo uses it twice: as the source of its starting
parameters, and as the bytecode reference that proves the vendored monetary policy is Curve's own
contract.

### sDOLA / crvUSD — market 0

| Contract | Address |
|---|---|
| Vault | `0x2b5a321C3cb1F33e1ABECD047C2649D0b4C47eBa` |
| Controller | `0xC77d97cF01737EB7aCE46cAb7cd9F60eC51a40c0` |
| AMM | `0xbf6f64B741164c26023f97fAaEA8e02453c27442` |
| Price oracle (`ERC4626EMAWrapper`) | `0x0117ba42D18EaC940b469F81eD0a135ca23A1003` |
| Rate calculator (`SDolaRateCalculator`) | `0x2BC89Ef5Fa2916bB63960be90B4F224a148450b8` |
| **Monetary policy (`HyperbolicDynamicMP`)** | **`0xE02C02FCeeF5608762058bFe79BFb4064DcAA7b8`** |

Its parameters: `A = 285`, `fee = 0.2%`, `loan_discount = 1.3%`, `liquidation_discount = 1%`,
`target_utilization = 90%`, `low_ratio = 0.5`, `high_ratio = 5`, `rate_shift = 0`.

`test/fork/WsgemMonetaryPolicyBytecode.fork.t.sol` deploys this repo's vendored initcode with that
market's constructor arguments and asserts the resulting runtime code equals the deployed
policy's, byte for byte. See [`../../script/bytecode/PROVENANCE.md`](../../script/bytecode/PROVENANCE.md).

## Upstream source

| | |
|---|---|
| Repository | `https://github.com/curvefi/curve-stablecoin` |
| Deployment records | `deployments/mainnet/llamalend-mainnet.jsonc` and `deployments/mainnet/markets/` |
| Docs | `https://docs.curve.finance/developer/llamalend-v2/overview` |
