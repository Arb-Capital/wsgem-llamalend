# wsgem-llamalend

## Oracle feed cadence — weekly today, possibly per-block later

The wsgem NAV feed (the `pip` behind wstGBP) currently publishes on a **weekly** cadence
(~6.8 bp per publication, ~3.54% APR). An upgrade to a **per-block accumulator** — continuous
accrual instead of discrete weekly publications — has been discussed and is considered a
plausible future for the feed.

The deployed system is designed to survive that transition with no redeploy and no governance
action. `MIN_CHECKPOINT_SPACING` (1 day) in `WsgemRateCalculator` is the cadence bridge: inert
at the weekly cadence, it becomes the checkpoint anchor under continuous accrual, turning the
measurement window into a rolling `RATE_INTERVALS × 1 day` of realised yield.

Implications when working in this repo:

- Do not tune parameters, write tests, or add logic that assumes the weekly cadence is
  permanent. Both regimes must keep working from one deployment.
- The floor must stay well under the publication cadence (so it never defers a genuine weekly
  publication) and strictly under `MAX_PUBLICATION_GAP` (enforced in the constructor).

Details: docs/03-rate-calculator-and-monetary-policy.md ("If the cadence changes") and
docs/04-parameters.md.
