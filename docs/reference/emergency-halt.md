# The halt vote, drafted in advance

[07-operations.md](../07-operations.md) names `set_borrow_cap(controller, 0)` as the emergency
stop and flags the reason it must exist before launch rather than be written mid-incident: while
an oracle is frozen, `borrow_more` stays live against the held price. A DAO vote follows the
ordinary governance timeline, so the draft has to be the thing that is ready — the halt is
submitted at the first sign, not after the diagnosis.

## When to submit

Submit first, diagnose second. The halt is safe by construction — repayment and liquidation stay
open, so it traps nobody — and a later vote restores the cap. Triggers, from the incident pages of
[07-operations.md](../07-operations.md):

- The oracle reports `frozen()` or `fxFrozen()` and the outage is not clearing.
- A publication looks erroneous, in either direction. A wrong downward publication liquidates
  irreversibly; a wrong upward one lends against value that is not there.
- tGBP trades materially away from sterling. The conversion prices GBP, not tGBP, and the oracle
  will not notice — see the instance sheet's
  [unhedged-peg note](../instances/wstgbp-crvusd.md).
- The wrapper's redemption gates close unexpectedly (`canPass`, `burnable()`, a non-zero
  `cooldown()`), or the gem pauses — either one severs the liquidator exit while the market
  keeps quoting.
- The pip's key or proxy is suspected compromised.

A cause in the wsgem or its feed is shared by **both** wstGBP markets: halt both. A cause in the
conversion legs belongs to wstGBP/crvUSD alone.

## The call

One call per market, from the factory's admin, on the Configurator:

```
Configurator: 0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC

  set_borrow_cap(<controller>, 0)
```

```bash
cast calldata "set_borrow_cap(address,uint256)" $WSGEM_CONTROLLER 0
```

| Market | Controller |
|---|---|
| wstGBP/tGBP | _(fill at deploy — [instances/wstgbp.md](../instances/wstgbp.md))_ |
| wstGBP/crvUSD | _(fill at deploy — [instances/wstgbp-crvusd.md](../instances/wstgbp-crvusd.md))_ |

Confirm the executing admin at submission time, same three reads as
[06-post-deployment.md](../06-post-deployment.md) step 2. Whether any faster-than-vote emergency
power exists over the Configurator is a question to settle with the Curve side **before** launch,
not during an incident; record the answer here when it is settled.

## Proposal text

> **Emergency: set the wstGBP/&lt;borrowed&gt; borrow cap to zero**
>
> This vote calls `set_borrow_cap(<controller>, 0)` on the Configurator
> (`0x6065858d0eF0AA240DFdf6f1A0B2ae34B41f49bC`).
>
> It stops new borrowing in the wstGBP/&lt;borrowed&gt; market immediately. Nothing else changes:
> repayment, collateral recovery through repayment, and liquidation all remain open, so no
> position is trapped. The reason is &lt;one sentence: what signal fired&gt;. The halt is
> precautionary and reversible — a later vote restores the cap once the cause is understood.

## Re-opening

The cap comes back by an ordinary [06-post-deployment.md](../06-post-deployment.md) vote, and only
after the pre-vote verification there passes again in full: oracle live and converged, cause
diagnosed and written up, and the liquidation-exit measurement in the instance sheet re-run — an
incident is exactly when venue depth moves.
