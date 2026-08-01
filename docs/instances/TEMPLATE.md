# Instance: `<SYMBOL>`

> Copy this file to `docs/instances/<slug>.md`, copy `script/WstGBP.s.sol` to
> `script/<Symbol>.s.sol` and change its constants, then work the runbook. Nothing in `src/`,
> `script/WsgemLlamalendDeploy.s.sol` or `docs/00`–`docs/08` should need editing. If it does, that
> is a bug in the generic layer — fix it there.

## The token

| | Value | Runbook variable |
|---|---|---|
| wsgem (collateral) | `0x…` | `$WSGEM` |
| gem (borrowed) | `0x…` | `$GEM` |
| Feed (`pip`) | `0x…` | |
| wsgem decimals | 18 | |
| gem decimals | 18 | |
| NAV publication cadence | | |
| Yield per publication | | |
| Redemption spread / depth | | |
| Audit / source | | |

Both tokens must be 18 decimals. The shims refuse anything else — the WAD identity between "NAV"
and "collateral price in borrowed-token terms" only holds for an 18/18 pair.

## Parameters

Justify each against [../04-parameters.md](../04-parameters.md) rather than copying.

| Parameter | Value | Why |
|---|---|---|
| `MAX_UPSIDE_SPEED` | | One publication of yield absorbed in hours; a month of allowance far below 10% |
| `RATE_INTERVALS` | | ≥ 2. More buys jitter rejection, costs lag after a rate change |
| `MAX_PUBLICATION_GAP` | | Comfortably above the publication cadence |
| `MIN_CHECKPOINT_SPACING` | | Well under the cadence and the grace; the continuous-accrual window is `RATE_INTERVALS ×` this |
| `A` | | Does the pair gap or drift? |
| `fee` | | Within `min(1e18 * 4 / A, 1e17)` |
| `loan_discount` | | |
| `liquidation_discount` | | Must clear the redemption spread with margin |
| `supply_limit` | | |
| `target_utilization` | | |
| `low_ratio` / `high_ratio` / `rate_shift` | | |

## Deployed addresses

Fill in as you go. These also go into the deployment record and the governance
proposal.

### Oracle — step 1 of [../05-deploy-mainnet.md](../05-deploy-mainnet.md)

| Contract | Address |
|---|---|
| `WsgemLlamalendOracle` | _(after 05 step 1)_ |
| Deployed at block | |
| Observed across a publication | _(05 step 2 — do not skip)_ |

### Market — step 3

| Contract | Address |
|---|---|
| `WsgemRateCalculator` | _(after 05 step 3)_ |
| `HyperbolicDynamicMP` | |
| Vault | |
| Controller | |
| AMM | |
| Factory market index | |

### Governance — [../06-post-deployment.md](../06-post-deployment.md)

| | Value |
|---|---|
| Vote ID | _(after 06 step 2)_ |
| Executed at block | |
| `borrow_cap` | |
| `admin_percentage` | |

## Instance-specific notes

Anything about this wsgem that a reader of the generic runbook would not know: who holds the feed
key, what the pause history looks like, whether the gem has its own oddities, existing liquidity in
the pair, anything a Curve risk reviewer will ask about.
