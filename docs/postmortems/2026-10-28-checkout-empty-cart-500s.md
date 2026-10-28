# Postmortem: checkout failing for empty carts (28 October 2026)

| | |
|---|---|
| **Status** | Resolved |
| **Severity** | SLO breach: the checkout error budget was used up |
| **Author** | Robert Olwoch |
| **Detected** | 20:35, by the `CheckoutErrorBudgetFastBurn` alert in Slack |
| **Fixed** | 21:01 (deploy), alert resolved 21:05 |
| **SLO** | [docs/slo/checkout.md](../slo/checkout.md): 99% of checkouts succeed over 7 days |

All times are East Africa Time (UTC+3), 28 October 2026.

This is a blameless postmortem. It is about what the system and the process
allowed to happen, not about who wrote which line.

## Summary

For about 3 hours 40 minutes, roughly every second checkout failed with
an HTTP 500. The failing requests were checkouts sent with a cart that had no
items in it. `payment` crashed on them (`'NoneType' object is not iterable`)
instead of rejecting them. The problem was invisible until the checkout SLO
and its alerts were installed at 20:30; the alert fired 5 minutes later.
The cause was found in about 10 minutes using the logs and traces, and a
fix that answers these requests with 400 was live at 21:01.

## Impact

| | |
|---|---|
| Checkouts in the 5 hours to 21:15 | 752 |
| Failed with 5xx | **383 (50.9%)** |
| Checkout success, rolling 7 days, at 21:15 | 50.23% (target 99%) |
| Error budget left, rolling 7 days | **-4877%** (used up about 50 times over) |
| Checkout latency | not affected (98.31% under 1 s) |

**Who was affected:** all traffic on this cluster comes from the load
generator, and the failing requests were the ones it sends on purpose with an
empty cart (user `partner-57`). Valid checkouts kept working throughout:
items were still being sold (Items sold/hour stayed between about 200 and
290). So no real customer lost a sale. What failed was the shop's handling
of bad input: a request that should have been turned away with "cart not
valid" crashed the service instead, and the SLO correctly counted that as the
shop's failure.

**Error budget policy:** the budget is used up, so the policy in the SLO
document applies: no new checkout features until the budget recovers, and the
action items below come first. Because the window is 7 days, the afternoon's
failures stay in it until 4 November 2026.

## Timeline

| Time | What happened |
|---|---|
| ~17:20 | The load generator starts (5 simulated shoppers, errors on). The `partner-57` checkouts start failing with 500. Nothing alerts on it, because no SLO or alert exists yet. |
| ~17:20-20:30 | The failures are visible to anyone who looks: the RED dashboard shows payment errors (from Step 2) and Loki has the error lines (from Step 3), but nothing tells anyone to look. |
| 20:02 | While choosing the SLO target, 3 hours of data show only 45.31% of checkouts succeed (298 of 546 failed). The SLO is written knowing it will start out broken. |
| 20:30 | SLO recording rules, burn-rate alerts and Slack routing installed (`install-monitoring.sh`). |
| **20:35** | **Detected.** `CheckoutErrorBudgetFastBurn` posts to `#all-robot-shop-alerts`: burn rate 60.11x, with the runbook link. |
| 20:35-20:43 | Runbook steps 1-2: the dashboard shows only payment failing (success 45.87%, budget -5313%, burn rate 59). The payment pod is `Running` with no restarts, so the problem is in how it handles requests. |
| ~20:43-20:46 (screenshot times) | **Cause found.** Runbook step 3: the failed checkouts in Jaeger have only 2 spans (payment crashed before calling anything); Loki `{service="payment"} \|= "NoneType"` shows `'NoneType' object is not iterable` on `POST /pay/partner-57`. The Grafana split view links the log line and its trace by `trace_id`. |
| 20:36-20:54 | Fix written (`payment` answers a cart with no items with 400) and tested locally. CI on the SLO work fails `promtool test rules`, which exposes two bugs in the SLO rules (see "What went poorly"); they are fixed in the same PR. |
| 20:57 | Fix merged (PR #13). The "payment image" workflow builds and pushes `rs-payment:2.1.0-otel.2`. |
| 20:58 | `CheckoutErrorBudgetSlowBurn` also posts to Slack (53.13x), although Alertmanager is set to mute it while the fast-burn alert fires. See open questions. |
| 21:00 | Corrected SLO rules applied (`kubectl apply`). |
| **21:01** | **Fix deployed.** PR #14 (chart switches to `2.1.0-otel.2`) merged; `deploy-shop.sh` run. `partner-57` checkouts now get 400. |
| **21:05** | **`CheckoutErrorBudgetFastBurn` RESOLVED** in Slack. |
| 21:15 | Last 15 minutes (21:00-21:15): 23 checkouts OK (200), 18 rejected as invalid (400), 12 failed (500) from before the new pod took over. Live 5xx error rate 0.00%; 1-hour burn rate down to 34.1 and falling. |

**Time to detect** (after alerting existed): 5 minutes. **Time from
alert to fix live:** 26 minutes. **Time the problem existed unseen:** about
3 hours 15 minutes, the real cost here.

## Root cause

`payment/payment.py` checked the cart like this:

```python
# check that the cart is valid
# this will blow up if the cart is not valid
has_shipping = False
for item in cart.get('items'):
```

A cart without `items` (`{"total": 0, "tax": 0}`) makes `cart.get('items')`
return `None`, and looping over `None` raises `TypeError`. payment's catch-all
error handler turns *every* exception into a 500, so a client's bad request
looked exactly like the server breaking. The comment shows the original
authors knew it would "blow up"; the shop is a demo built to produce errors.
Nothing between them and this cluster turned that known behaviour into
something anyone would act on.

## Contributing factors

1. **No input validation before use.** The cart was trusted until the loop
   failed on it. The later check (`total == 0 or no shipping`, which returns
   400) was never reached.
2. **One error handler for everything.** `@app.errorhandler(Exception)`
   returns 500 for any exception, so client mistakes and real failures look
   the same in metrics, logs and the SLO.
3. **Observability without alerting.** For three hours the data was on a
   dashboard and in Loki, but a dashboard only helps someone who is already
   looking. The SLO turned "some red on a graph" into a message in Slack.
4. **No tests for payment.** Nothing exercised `/pay` with a bad cart.

## What went well

- **The alert fired 5 minutes after it was installed**, with the burn rate,
  severity and a runbook link, in the channel.
- **The runbook led straight to the cause.** Its trace table ("only
  `POST /pay/<id>`, 2 spans in total: payment crashed in its own code") and
  its `|= "NoneType"` query were exactly what happened.
- **Logs and traces linked by `trace_id`** (Step 4) meant one click from the
  error log line to the request that caused it.
- **The fix was small and safe**: one check of a few lines, tested locally before it went in,
  and built and smoke-tested by CI before it reached the cluster.
- **CI caught real bugs in the SLO rules** (the promtool tests) before they
  could hide the recovery.

## What went poorly

- **Two bugs in my own SLO rules** surfaced during the incident:
  1. A window with no 5xx at all gave *no data* instead of 0% errors. After
     the fix, the budget panel would have gone blank instead of showing the
     recovery.
  2. The latency SLI showed *No data*: Prometheus 3 stores the 1 s bucket as
     `le="1.0"`, and the rule looked for `le="1"`.
  Both were fixed (`or vector(0)`, `le=~"1|1.0"`) and are now covered by tests.
- **The fix needed two PRs.** CI checks that every image in the chart exists,
  so the chart couldn't point at `2.1.0-otel.2` until the first PR had built
  it. That added about 4 minutes and an extra step during an incident.
- **The slow-burn alert fired during the fast-burn one**, which the
  inhibit rule should have prevented. One extra message in Slack; cause
  unknown (open question 1).

## Where we got lucky

The failing requests were synthetic. If a real client had sent malformed carts
(an app bug, a bad release of the web front end), real customers would have
seen 500s for three hours before anyone was told.

## Action items

| # | Action | Type | Owner | Status |
|---|---|---|---|---|
| 1 | Reject carts with no items with 400 before using them | fix | Robert | **Done** (PR #13, #14) |
| 2 | Fix the SLO rules: 0% instead of no data; `le="1.0"` | fix | Robert | **Done** (PR #13) |
| 3 | Add tests for `payment` `/pay` (empty cart, no body, valid cart) and run them in the payment image workflow | prevent | Robert | Open |
| 4 | Make the error handler return 400 for bad input (`TypeError`/`KeyError` from the request body) and 500 only for real failures | prevent | Robert | Open |
| 5 | Ship image and chart changes in one PR: let CI accept an image tag that the same PR builds | process | Robert | Open |
| 6 | Find out why `CheckoutErrorBudgetSlowBurn` was not muted at 20:58 (check `amtool` inhibition and the Alertmanager logs) | investigate | Robert | Open |
| 7 | Fix the RabbitMQ idle-connection drops seen in Steps 3-4 (`missed heartbeats`, a failed first `robot-shop send` then a retry) | prevent | Robert | Open |
| 8 | Review the 99% / 7-day target when the budget has recovered (4 Nov 2026) | review | Robert | Open |

## Open questions

1. **Why wasn't the slow-burn alert muted?** The inhibit rule
   (fast burn mutes slow burn for the same `slo`) is in the rendered config
   and passed `amtool check-config`. My first guess was that re-applying the
   SLO rules reset the fast-burn alert, but the rules were re-applied at
   21:00, after the slow-burn message at 20:58, so that isn't it.

## Lessons

- **An SLO is what makes a dashboard useful.** The errors were on screen for
  three hours; nobody was told until there was a target and a budget.
- **Count client errors as client errors.** Whether a failure is 4xx or 5xx
  decides whether it spends the error budget. Getting that wrong made a
  harmless bad request look like an outage.
- **Test the monitoring too.** The promtool tests found two bugs that would
  have made the dashboard lie during the recovery.
