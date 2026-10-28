# SLO: Robot Shop checkout

| | |
|---|---|
| **Service** | Robot Shop checkout (`payment`, reached through the `web` gateway) |
| **Owner** | Robert Olwoch |
| **Written** | 28 October 2026 |
| **Status** | Active. Breached when written (see "Where we started") |
| **Review** | After the incident drill, then once a month |

## Why checkout

Checkout is where the shop makes money. If someone can't browse the catalogue
they might come back later; if their payment fails, the sale is gone.

It is also the journey this project can see best:

- **Metrics:** every checkout passes the web gateway, which counts requests,
  status codes and timings (Step 2).
- **Logs:** payment's logs are in Loki, searchable by level (Step 3).
- **Traces:** payment is traced with OpenTelemetry, so a slow or failed
  checkout can be opened step by step in Jaeger (Step 4).

## What counts as a checkout

Every `POST /api/payment/pay/<user>` request that reaches the web gateway.
It is measured at the gateway (nginx), not inside payment, so a checkout
where payment is down or never answers still counts. From the customer's
side, that is a failed checkout too.

## The SLIs (what is measured)

| SLI | Good event | Measured by |
|---|---|---|
| **Availability** | The checkout did **not** end with a 5xx status | `nginx_http_response_count_total{service="payment", method="POST"}` |
| **Latency** | The checkout finished in **1 second or less** | `nginx_http_response_time_seconds_hist_bucket{le="1"}` |

**4xx responses count as good.** A 4xx means the request itself was wrong
(an invalid cart, an unknown user), and the shop answered it correctly. A 5xx
means the shop failed. This decision matters: see "Where we started".

## The objectives

| SLO | Target | Window | Error budget |
|---|---|---|---|
| Availability | **99%** of checkouts succeed | rolling 7 days | 1% of checkouts can fail |
| Latency | **95%** of checkouts take 1 s or less | rolling 7 days | 5% can be slower |

**Why 99% and not 99.9%:** payment runs as a single replica on a 3-node
course cluster, and every checkout depends on an outside payment gateway that
this team doesn't control. 99.9% (about 32 failures a week at today's traffic)
would be a promise the setup can't keep. 95% would let a badly broken checkout
pass unnoticed. 99% allows about 320 failures a week at roughly 190
checkouts an hour.

**Why 7 days:** Prometheus keeps 7 days of data (`retention: 7d`), and a week
covers both quiet and busy days.

**Why 1 second:** when measured, p95 was 865 ms and p99 1.76 s. The traces
show most of that time is the outside payment gateway (239 ms of a 258 ms
checkout in trace `12334ad`), so 1 s gives normal checkouts room while still
catching a gateway that gets really slow.

## Where we started (28 October 2026)

Measured from Prometheus over the 3 hours before writing this:

| | |
|---|---|
| Checkouts | 546 (247 succeeded, 298 failed with 500) |
| Success rate | **45.31%** (per hour: 40.6%, 48.9%, 45.6%) |
| Latency p50 / p95 / p99 | 18 ms / 865 ms / 1757 ms |

**The SLO was broken from the first minute.** At 55% failures the error
budget burns about 55 times too fast; a week's budget lasts about 20 minutes.

Almost all the failures are one request. The load generator sends
`POST /api/payment/pay/partner-57` with a cart that has no items in it, and
payment crashes with `'NoneType' object is not iterable` (a 500) instead of
rejecting the bad cart with a 400. The logs (Step 3) and traces (Step 4) both
show it. This is the Step 6 incident.

## Error budget policy

The budget is what makes the SLO more than a number: it decides what happens
next.

| Budget left (7 days) | What happens |
|---|---|
| **More than 25%** | Normal work. Changes to checkout can ship as usual. |
| **0-25%** | Be careful: changes to payment, cart or web need a second look, and anything risky waits. |
| **Used up (0% or below)** | **Feature freeze on checkout.** Only fixes that make checkout more reliable ship until the budget recovers. The cause gets a blameless postmortem. |
| **One incident uses more than 20% of the budget** | That incident gets a postmortem, even if the budget isn't used up. |

What does not count against the budget: failures during a planned maintenance
window announced in advance (there are none yet), and the outside payment
gateway being down. A gateway outage is still recorded, but it is a reason to
talk to the provider, not to freeze our own work.

## Alerts

Defined in `observability/slo/checkout-slo-rules.yaml`, using burn rates
(Google SRE Workbook, chapter 5). The burn rate is how fast the budget is
being used: 1x uses exactly a week's budget in a week.

| Alert | Fires when | Means | Goes to |
|---|---|---|---|
| `CheckoutErrorBudgetFastBurn` | burn rate above **14.4x** over 1 hour **and** 5 minutes | budget gone in under 12 hours | Slack, `critical` |
| `CheckoutErrorBudgetSlowBurn` | burn rate above **6x** over 6 hours **and** 30 minutes | budget gone in about a day | Slack, `warning` |
| `CheckoutLatencyBudgetFastBurn` | over 30% of checkouts slower than 1 s, over 1 hour **and** 5 minutes | latency budget burning 6x too fast | Slack, `warning` |

Each alert checks a long window (is this real?) and a short one (is it still
happening?), so it neither fires on a 2-minute blip nor keeps firing for an
hour after a fix. Every alert links to the runbook:
[docs/runbooks/checkout-slo.md](../runbooks/checkout-slo.md).

The Slack webhook URL is stored only in the Kubernetes Secret
`alertmanager-slack`, never in Git.

## Where to see it

- **Grafana**, dashboard *Robot Shop - Requests, Errors, Latency*, top row:
  success over 7 days, budget left, burn rate and the latency SLI.
- **Prometheus**: the recorded series `slo:checkout_errors:ratio_rate*`,
  `slo:checkout_slow:ratio_rate*` and `slo:checkout_error_budget:remaining7d`.

## Known limits

- The SLI is measured at the gateway, so a customer who gives up before the
  request reaches it isn't counted.
- The load generator's traffic is the only traffic. Real customers would
  behave differently, and the target should be reviewed against real data.
- 7 days of history is all Prometheus keeps, so a 30-day SLO isn't possible
  on this setup.
