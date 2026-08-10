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
here; recorded because a blueprint change means later markets are not the same code as
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

## Reference deployments

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

### svZCHF / crvUSD — market 3

The donor for the cross-currency instances' risk parameters, and the closest published analogue by
a distance: a foreign-currency yield-bearing wrapper borrowed against a dollar stablecoin, which is
wstGBP/crvUSD with the Swiss franc in place of sterling.

| Contract | Address |
|---|---|
| Vault | `0xCb6e2c3d9Dba8fe6245B2c969320F2485dFce2FD` |
| Controller | `0xFd85e847cDd2549f213E276e4B57B0690169F043` |
| AMM | `0xc8C469e3964707295302299DBbF88F13EB9C40a3` |
| Collateral (svZCHF) | `0xE5F130253fF137f9917C0107659A4c5262abf6b0` |
| Price oracle | `0xa44b313A8D3Fedc6F024EC25CfBF2E15487c1951` |
| Monetary policy | `0x547De3c2E2960Cc7879EE6626F2763cbc24d4921` |

Its parameters: `A = 180`, `fee = 0.05%`, `loan_discount = 4.3%`, `liquidation_discount = 2.3%`,
`supply_limit` unlimited. Note it does **not** run `HyperbolicDynamicMP` — its
`RATE_CALCULATOR()` reverts — so it is a donor for the risk set only, not for the policy curve.

Its oracle composes `ZCHF/crvUSD x svZCHF.convertToAssets(1e18)` entirely from Curve pool moving
averages plus the crvUSD aggregator below — no Chainlink anywhere. That route needs deep Curve
pools in the foreign currency, which ZCHF has and tGBP does not, which is why the wstGBP instances
take the sterling leg from Chainlink instead.

## Price feeds — the cross-currency instances

Read by `WsgemFxLlamalendOracle`. The same-currency instance reads none of these: its price is the
wrapper's own redemption quote with no conversion term.

| Feed | Address | Shape |
|---|---|---|
| Chainlink GBP/USD | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` | `AggregatorV3`, 8 dec, 24 h heartbeat, 0.15% deviation. Publishes through weekends |
| Curve crvUSD aggregator | `0x18672b1b0c623a30089A280Ed9256379fb0E4E62` | `price()` → WAD. EMA over five crvUSD/stable pools. Admin is the DAO agent above |
| Chainlink frxUSD/USD | `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83` | `AggregatorV3`, 8 dec, 24 h heartbeat, 0.5% deviation |

Considered and **not** used, recorded so the question is not reopened without the reason:

| | Address / id | Why not |
|---|---|---|
| Chainlink CRVUSD/USD | `0xEEf0C605546958c1f899b6fB336C20671f9cD49F` | 0.5% deviation on a token that lives within basis points of a dollar. Curve's own aggregator is what Curve's crvUSD markets read and has no heartbeat |
| Chainlink FRAX/USD | `0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD` | Prices the LEGACY FRAX token, not frxUSD. Near a percent apart, in the direction that over-values collateral |
| Chainlink GBP/USD Data Stream | `0x00086bdceb0b66669c04e7315815614f4ad910e6bb0134e2a7b9070145eb2e7b` | Pull-based: a signed report verified in a payable transaction. Llamalend reads `price()` as a `view`. Consuming it needs a keeper pushing reports into storage — the discretionary party this repo exists to remove |
| Curve frxUSD/crvUSD pool | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | The Curve-native route for frxUSD: one ~$13.5M pool on a 866 s average, divided into the crvUSD aggregator. A dedicated OCR feed is the better of the two |

Confirm any of them before relying on it:

```bash
cast call $FEED "description()(string)" --rpc-url $ETH_RPC_URL
cast call $FEED "decimals()(uint8)"     --rpc-url $ETH_RPC_URL
cast call $FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $ETH_RPC_URL
```

## Upstream source

| | |
|---|---|
| Repository | `https://github.com/curvefi/curve-stablecoin` |
| Deployment records | `deployments/mainnet/llamalend-mainnet.jsonc` and `deployments/mainnet/markets/` |
| Docs | `https://docs.curve.finance/developer/llamalend-v2/overview` |
