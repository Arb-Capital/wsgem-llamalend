# 8 — Integration

For anyone building against a deployed market rather than deploying one.

## Finding the market

`LendFactory` is the canonical registry — there is no separate one.

```solidity
ILendFactory f = ILendFactory(0x8f6B56EC5ddF1F2691a1059f1D3cd97Ac9EaB0bd);

uint256 n = f.market_count();
ILendFactory.Market memory m = f.markets(i);
// m.vault, m.controller, m.amm, m.collateral_token, m.borrowed_token,
// m.price_oracle, m.monetary_policy

uint256 id = f.vaults_index(vault);   // reverse lookup; reverts if unregistered
```

Field order mirrors the Vyper struct. Getting it wrong shifts every address by a slot and decodes
silently.

## Lending: the vault

Plain ERC-4626 over the borrowed token. `deposit`, `mint`, `withdraw`, `redeem` and every
`preview*` / `max*` behave per spec.

Three things that are not obvious:

**Virtual shares.** The vault carries 1000 virtual shares as inflation-attack defence. They are not
minted and not in `totalSupply`, so a fresh vault does **not** start at a 1:1 asset-to-share ratio.
Use `convertToShares` / `convertToAssets`; never assume a ratio.

**Deposits are capped.** `max_supply` is DAO-configurable — zero disables deposits, `max(uint256)`
is unlimited. Check `maxDeposit()` / `maxMint()` before depositing rather than reverting.

**Withdrawals are bounded by idle liquidity.** Assets currently lent out cannot be withdrawn until
repaid. `maxWithdraw` / `maxRedeem` already account for this, so use them rather than
`convertToAssets(balanceOf(user))`.

Yield accrues passively through a rising `pricePerShare`. There is nothing to claim.

| View | Meaning |
|---|---|
| `pricePerShare(bool isFloor)` | Share price, 1e18 |
| `lend_apr()` | Lender yield after admin fees, 1e18 |
| `borrow_apr()` | Current borrow rate, 1e18 |
| `totalAssets()` | Lent + idle |

## Borrowing: the controller

```solidity
create_loan(collateral, debt, N, _for, callbacker, calldata)
borrow_more(...) / add_collateral(...) / remove_collateral(...)
repay(...)          // `shrink: true` exits soft liquidation by cutting the converted part
liquidate(...)
```

V2 replaced V1's single `health_calculator()` with a preview per operation — quote before
committing rather than simulating:

```
create_loan_health_preview      borrow_more_health_preview
add_collateral_health_preview   remove_collateral_health_preview
repay_health_preview            liquidate_health_preview
```

`max_borrowable(d_collateral, N, user)` is cap-aware — it accounts for the borrow cap and available
liquidity, so it is the right number to show a user.

**A zero borrow cap is a normal state, not an error.** Every market ships with one, and it stays
until a DAO vote lifts it. `borrow_cap()` reading zero means the market exists but is not open;
surface that as "not yet live" rather than as a failure.

## Pricing

The market's oracle is `m.price_oracle`, and for a wsgem market it is this repo's shim.

```solidity
uint256 p = IPriceOracle(oracle).price();   // wsgem in gem, 1e18
```

Integrating against it, three properties matter:

- **It never returns zero.** A paused or unreadable feed freezes the last good price.
- **It can lag the underlying feed.** Upward moves are rate-limited to 0.25%/day, so an ordinary
  weekly step takes about 6.5 hours to be fully reflected. Compare `price()` against `spotPrice()`
  if you need to know whether the limit is currently binding. Downward moves are not limited.
- **`price_w()` is not a different number.** It equals `price()` within a call; the difference is
  only that it persists the checkpoint.

For a display price, use `price()`. For "what does the feed actually say", use `spotPrice()` and
handle its zero.

The AMM's `price_oracle()` returns the *price* the AMM is working from; `price_oracle_contract()`
returns the oracle *address*. Easy to confuse.

## Rates

```solidity
IHyperbolicDynamicMP mp = IHyperbolicDynamicMP(m.monetary_policy);
mp.target_rate();   // per-second base rate, clamped
mp.target_apr();    // annualised
mp.rate();          // actual rate at current utilization
```

The base rate follows the wsgem's realised yield across the last four publications, and is exactly
constant between them. A `target_rate()` of exactly `317097920` means the floor — expected before
the calculator has recorded two publications.

## Things worth telling your users

- The collateral's price comes from a weekly-published NAV controlled by a permissioned key, not
  from a market. Upward moves are rate-limited; downward moves are not.
- A paused feed does not halt the market. Positions keep accruing interest against a frozen price.
- The market can be closed to new borrowing by a DAO vote at any time; repayment and liquidation
  stay open.
- Withdrawal from the vault depends on utilization, not just on balance.

## Interfaces

`src/interfaces/` carries Solidity translations of Curve's Vyper interfaces — `ILendFactory`,
`ILendController`, `IVault`, `IAMM`, `IConfigurator`, `IPriceOracle`, `IRateCalculator`,
`IMonetaryPolicy` — scoped to what this repo needs. They are a usable starting point but not
exhaustive; the upstream `.vyi` files are authoritative.
