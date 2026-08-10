# Instance: `wstGBP / crvUSD`

The second market, and the first cross-currency one. Collateral wstGBP, borrowed **crvUSD** — not
the wsgem's own gem. That single change is what the whole instance is about: the wrapper's
redemption quote is denominated in tGBP, so it is no longer Llamalend's collateral-in-borrowed
price, only one term of it.

Read [wstgbp.md](wstgbp.md) first. Everything about the collateral — the wrapper, the feed, the
publication cadence, who holds the key, what the pause history looks like — is the same and is
recorded there rather than repeated here.

## The tokens

| | Value | Runbook variable |
|---|---|---|
| wsgem (collateral) | [`0x57C3571f10767E49C9d7b60feb6c67804783B7aE`](https://etherscan.io/address/0x57C3571f10767E49C9d7b60feb6c67804783B7aE) | `$WSGEM` |
| gem (the quote's denomination, **not** borrowed) | [`0x27f6c8289550fCE67f6B50BeD1F519966aFE5287`](https://etherscan.io/address/0x27f6c8289550fCE67f6B50BeD1F519966aFE5287) | `$GEM` |
| **borrowed** | crvUSD [`0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E`](https://etherscan.io/address/0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E) | `$BORROWED` |
| Feed (`pip`) | [`0x6A79dCe61A12aa4b75449e0B03746260765D07dF`](https://etherscan.io/address/0x6A79dCe61A12aa4b75449e0B03746260765D07dF) | |
| Decimals | 18 / 18 / 18 | |

All three must be 18 decimals. `WsgemFxLlamalendOracle` refuses anything else: the wsgem/gem pair is
what makes `burncost()` a WAD quote, and the borrowed token's 18 decimals are what make the
converted result a WAD price.

## The conversion

```
price = burncost (tGBP per wstGBP)  ×  GBP/USD  ÷  crvUSD/USD
```

| Leg | Source | Shape |
|---|---|---|
| GBP/USD | Chainlink [`0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5`](https://etherscan.io/address/0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5) | `AggregatorV3`, 8 dec, 24 h heartbeat, 0.15% deviation |
| crvUSD/USD | Curve [`0x18672b1b0c623a30089A280Ed9256379fb0E4E62`](https://etherscan.io/address/0x18672b1b0c623a30089A280Ed9256379fb0E4E62) | `price()` → WAD, EMA over five crvUSD/stable pools, no heartbeat |

Worked example, read from mainnet at plan time:

```
burncost          1.005529808480920241   (WAD, tGBP per wstGBP)
GBP/USD           1.34714                (1e8)
crvUSD/USD        0.999928817153633616   (WAD)
→ price           1.354685857519602100   (WAD, crvUSD per wstGBP)
```

**Why Curve's aggregator and not Chainlink's CRVUSD/USD feed**
([`0xEEf0C605…`](https://etherscan.io/address/0xEEf0C605546958c1f899b6fB336C20671f9cD49F), 8 dec,
24 h heartbeat, 0.5% deviation): it is what Curve's own crvUSD markets read, what the comparable
svZCHF/crvUSD market's oracle reads, and it has no heartbeat to go stale. A 0.5% deviation
threshold on a token that lives within a few basis points of a dollar is a feed that can sit at its
last value across the entire range that matters.

The cost, stated plainly: its "dollar" is a basket of dollar stablecoins rather than Chainlink's
USD, so the two legs leave a small residual basis. And its `admin` is the Curve DAO agent
[`0x40907540…`](https://etherscan.io/address/0x40907540d8a6C65c637785e8f8B742ae6b0b9968) — the same
agent that admins the LendFactory — which chooses the pools it averages over. See
[../02-oracle-shim.md](../02-oracle-shim.md#the-cross-currency-shim).

**Why not the Chainlink Data Stream.** A GBP/USD Data Stream exists
(`GBP/USD-Streams-ForexPrice-DS-Premium-Global-008`, feed id
`0x00086bdceb0b66669c04e7315815614f4ad910e6bb0134e2a7b9070145eb2e7b`) and is lower latency. It
cannot be used: Data Streams is pull-based — a signed report fetched off-chain and verified in a
payable transaction — and Llamalend reads `price()` as a `view` from inside the AMM. Consuming one
would mean a keeper pushing verified reports into a storage contract, which reintroduces exactly
the discretionary party this repo's ownerlessness exists to remove.

## Parameters

Shim and calculator values are carried over from [wstgbp.md](wstgbp.md) unchanged — same wsgem,
same feed, same cadence. The risk set is not: it comes from Curve's **svZCHF/crvUSD** market
(controller [`0xFd85e847cDd2549f213E276e4B57B0690169F043`](https://etherscan.io/address/0xFd85e847cDd2549f213E276e4B57B0690169F043)),
which is this market with the Swiss franc in place of sterling.

| Parameter | Value | Why |
|---|---|---|
| `MAX_UPSIDE_SPEED` | 0.25%/day (`28935185185`) | Binds on the NAV leg only. Same feed, same cadence, so the same number as the first instance |
| `MAX_FX_AGE` | 30 hours | 24 h heartbeat plus six hours of grace. Tighter freezes the market in ordinary operation |
| `RATE_INTERVALS` | 4 | Unchanged |
| `MAX_PUBLICATION_GAP` | 10 days | Unchanged |
| `MIN_CHECKPOINT_SPACING` | 1 day | Unchanged |
| `A` | 180 (~56 bp bands) | svZCHF/crvUSD. 285 would leave borrowers permanently in soft liquidation against a currency pair |
| `fee` | 0.05% | svZCHF/crvUSD. The AMM cap at A = 180 is ~2.22%, so the constraint is economic |
| `loan_discount` | **5%** | svZCHF/crvUSD's 4.3% + 70 bp. See below — the one number here that is ours |
| `liquidation_discount` | 2.3% | svZCHF/crvUSD, unchanged |
| `supply_limit` | unlimited | Not the borrow cap, which starts at zero |
| `target_utilization` | 90% | From the first instance; svZCHF/crvUSD runs a different policy contract entirely |
| `low_ratio` / `high_ratio` / `rate_shift` | 0.5 / 5 / 0 | Same |

### The 70 basis points

svZCHF/crvUSD's oracle composes Curve pool moving averages, which move with every trade. Ours
composes a Chainlink push feed, which moves only when a round fires — triggered at 0.15% on GBP/USD.
In a calm market the reported sterling price therefore sits routinely around that far behind, in
either direction, with nothing having failed, and 70 bp is roughly four times that typical lag.

The threshold triggers rounds rather than capping them, so it is not a bound: a move that outruns a
round leaves the price further behind by however much the market travelled meanwhile. The buffer is
sized against the ordinary case, not the fast one.

It is spent on `loan_discount` and not on `liquidation_discount` deliberately: that moves where a
borrower may **open** without moving where liquidation begins, so the buffer pays for the
borrower's entry rather than giving a soft-liquidating position more room to keep losing.

## Deployed addresses

### Oracle — step 1 of [../05-deploy-mainnet.md](../05-deploy-mainnet.md)

| Contract | Address |
|---|---|
| `WsgemFxLlamalendOracle` | _(after 05 step 1, `INSTANCE=WstGBPCrvUSD`)_ |
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

This vote is **separate** from the wstGBP/tGBP market's and from wstGBP/frxUSD's. Each market ships
with `borrow_cap == 0` and each needs its own.

## Instance-specific notes

**`WSGEM_ORACLE` is one variable serving three instances.** Every wstGBP instance shares a wsgem, a
gem, a pip and an upside speed, so any of their oracles passes every wiring check the deploy scripts
share — a live, healthy, self-consistent oracle for the wrong market is the one failure nothing
on-chain catches. What catches it is `_assertOracleExtra`, which each instance overrides with
something true only of its own oracle. Pinned by `test/WstGBPCrvUSDDeployScript.t.sol` against
mocks and by `test/fork/WstGBPCrvUSD.fork.t.sol` against live addresses — and symmetrically by the
frxUSD instance's own two suites. `make` echoes the pairing before every run.

**The conversion permits instantaneous price steps, by design.** Curve's post-sDOLA rule asks that
no Llamalend oracle permit an instantaneous jump for any reason; the NAV leg meets it, the
conversion does not. Chainlink rounds are discrete and unthrottled here, so a round steps the
reported price when it lands, and nothing caps that step: the deviation threshold triggers a round
rather than limiting one, so a fast market steps by several times it, and a halted leg that recovers
delivers the whole accumulated move at once. Expect this to come up in the DAO conversation;
the argument is in [../02-oracle-shim.md](../02-oracle-shim.md#where-the-rate-limit-binds--the-nav-leg-and-nowhere-else).

**tGBP ≈ GBP is assumed and unhedged.** The conversion prices *sterling*, and the quote is
denominated in *tGBP*. There is no tGBP/USD feed to check one against the other. A tGBP depeg moves
this market's collateral price by exactly the depeg, in the wrong direction, and nothing in the
oracle notices. This is a risk the same-currency instance does not carry at all — there, a tGBP
depeg moves collateral and debt together.

**The borrow rate is anchored to a sterling yield.** `WsgemRateCalculator` measures the
collateral's realised NAV yield (~3.54% APR), and `HyperbolicDynamicMP` takes it as the target
borrow rate. Against tGBP debt that makes a loop roughly break-even at target utilization; against
crvUSD debt it does not, because dollar rates are not sterling rates and the loop is a currency
carry trade. Reusing the calculator is a deliberate choice — see
[../04-parameters.md](../04-parameters.md) — not an oversight.

**The aggregator read is the dominant gas cost.** Curve's crvUSD aggregator walks every pool it
averages over and cost 116,892 gas cold when measured on mainnet. Every price this market reports
pays for it, and the oracle's cap for that leg (1,000,000) is a backstop against an unbounded loop
rather than a meaningful budget.
