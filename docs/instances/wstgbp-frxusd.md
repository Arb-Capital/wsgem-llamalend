# Instance: `wstGBP / frxUSD`

The third market, and the second cross-currency one. Collateral wstGBP, borrowed **frxUSD**.

Identical to [wstgbp-crvusd.md](wstgbp-crvusd.md) in every respect except the borrowed token and
where its dollar price comes from — both instances inherit `script/WstGBPFx.s.sol`, so they cannot
drift apart on anything else. Read that sheet for the shared reasoning: why the rate limit binds on
the NAV leg only, why the risk set comes from svZCHF/crvUSD, the tGBP peg assumption, the
sterling-yield borrow-rate anchor, and the `WSGEM_ORACLE` sharp edge. Only the differences are here.

## The tokens

| | Value | Runbook variable |
|---|---|---|
| wsgem (collateral) | [`0x57C3571f10767E49C9d7b60feb6c67804783B7aE`](https://etherscan.io/address/0x57C3571f10767E49C9d7b60feb6c67804783B7aE) | `$WSGEM` |
| gem (the quote's denomination, **not** borrowed) | [`0x27f6c8289550fCE67f6B50BeD1F519966aFE5287`](https://etherscan.io/address/0x27f6c8289550fCE67f6B50BeD1F519966aFE5287) | `$GEM` |
| **borrowed** | frxUSD [`0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29`](https://etherscan.io/address/0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29) | `$BORROWED` |
| Feed (`pip`) | [`0x6A79dCe61A12aa4b75449e0B03746260765D07dF`](https://etherscan.io/address/0x6A79dCe61A12aa4b75449e0B03746260765D07dF) | |
| Decimals | 18 / 18 / 18 | |

> **frxUSD is not FRAX.** The legacy FRAX token
> [`0x853d955aCEf822Db058eb8505911ED77F175b99e`](https://etherscan.io/address/0x853d955aCEf822Db058eb8505911ED77F175b99e)
> still exists, still trades, and sat about 90 basis points below a dollar when this was written.
> Both are 18 decimals and neither the preflight nor the oracle constructor separates them. Pinned
> by `test_theBorrowedTokenIsNotLegacyFrax`.

## The conversion

```
price = burncost (tGBP per wstGBP)  ×  GBP/USD  ÷  frxUSD/USD
```

| Leg | Source | Shape |
|---|---|---|
| GBP/USD | Chainlink [`0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5`](https://etherscan.io/address/0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5) | `AggregatorV3`, 8 dec, 24 h heartbeat, 0.15% deviation |
| frxUSD/USD | Chainlink [`0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83`](https://etherscan.io/address/0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83) | `AggregatorV3`, 8 dec, 24 h heartbeat, 0.5% deviation |

Worked example, read from mainnet at plan time:

```
burncost          1.005529808480920241   (WAD, tGBP per wstGBP)
GBP/USD           1.34714                (1e8)
frxUSD/USD        0.99987391             (1e8)
→ price           1.354760247916646700   (WAD, frxUSD per wstGBP)
```

**Why Chainlink here when the crvUSD instance uses a Curve aggregator.** There is no equivalent
Curve contract for frxUSD — `AggregatorStablePrice` is crvUSD's own. The Curve-native route would
be a single pool, frxUSD/crvUSD at
[`0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1`](https://etherscan.io/address/0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1)
(about $13.5M, `ma_exp_time` 866 s), divided into the crvUSD aggregator. That would rest the market
on one pool's fourteen-minute average rather than on an OCR set, plus a second Curve read. The
dedicated feed is the better of the two, so this instance takes it.

**Do not substitute Chainlink's FRAX/USD feed**
([`0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD`](https://etherscan.io/address/0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD),
1 h heartbeat, 1% deviation). It prices the legacy token, and the gap between them is near a
percent — in the direction that **over**-values collateral, because the borrowed token's quote is
the divisor. Pinned by `test_theBorrowedLegIsNotTheFraxFeed` and, against live answers, by
`test_theFrxUsdFeedIsFrxUsdAndNotFrax`.

Because both legs are Chainlink push feeds, `MAX_FX_AGE` bounds both. The crvUSD instance's Curve
leg has no publication time and nothing to bound.

## Parameters

Identical to [wstgbp-crvusd.md](wstgbp-crvusd.md) — both instances read them from
`script/WstGBPFx.s.sol`. Each instance has its own suite — `test/WstGBPFrxUSDDeployScript.t.sol`
here, `test/WstGBPCrvUSDDeployScript.t.sol` there — reading every value through *this* instance's
script rather than through the shared base, so an override added here in future is caught here.

| Parameter | Value |
|---|---|
| `MAX_UPSIDE_SPEED` | 0.25%/day (`28935185185`) |
| `MAX_FX_AGE` | 30 hours |
| `RATE_INTERVALS` / `MAX_PUBLICATION_GAP` / `MIN_CHECKPOINT_SPACING` | 4 / 10 days / 1 day |
| `A` / `fee` | 180 / 0.05% |
| `loan_discount` / `liquidation_discount` | 5% / 2.3% |
| `supply_limit` | unlimited |
| `target_utilization` / `low_ratio` / `high_ratio` / `rate_shift` | 90% / 0.5 / 5 / 0 |

## Deployed addresses

### Oracle — step 1 of [../05-deploy-mainnet.md](../05-deploy-mainnet.md)

| Contract | Address |
|---|---|
| `WsgemFxLlamalendOracle` | _(after 05 step 1, `INSTANCE=WstGBPFrxUSD`)_ |
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

Separate from every other instance's vote.

## Instance-specific notes

**No frxUSD market exists on Llamalend V2 yet.** All four markets on the factory at the time of
writing borrow crvUSD. There is no published analogue for the borrowed side, so the risk set comes
from svZCHF/crvUSD on the strength of the *collateral* being the comparable thing — a
foreign-currency yield-bearing wrapper. A Curve risk reviewer will ask about frxUSD liquidity and
about the absence of a precedent; both are fair questions and neither is answered by this repo.

**The conversion permits instantaneous price steps, by design.** Curve's post-sDOLA rule asks that
no Llamalend oracle permit an instantaneous jump for any reason; the NAV leg meets it, the
conversion does not. Chainlink rounds are discrete and unthrottled here, so a round steps the
reported price when it lands, and nothing caps that step: the deviation threshold triggers a round
rather than limiting one, so a fast market steps by several times it, and a halted leg that recovers
delivers the whole accumulated move at once. Expect this to come up in the DAO conversation;
the argument is in [../02-oracle-shim.md](../02-oracle-shim.md#where-the-rate-limit-binds--the-nav-leg-and-nowhere-else).

**Both conversion legs can go stale together.** They share a 24-hour heartbeat and a staleness
bound, so a Chainlink-wide outage freezes this market where it would only half-freeze the crvUSD
one. Freezing is the designed response either way — it keeps repayment and liquidation working —
but the exposure is wider here and `fxFrozen()` is the alarm.
