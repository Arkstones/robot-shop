# Runbook: checkout SLO alerts

For these alerts (`observability/slo/checkout-slo-rules.yaml`):

- `CheckoutErrorBudgetFastBurn` (critical)
- `CheckoutErrorBudgetSlowBurn` (warning)
- `CheckoutLatencyBudgetFastBurn` (warning). See [Checkouts are slow](#checkouts-are-slow).

The SLO itself is explained in [docs/slo/checkout.md](../slo/checkout.md).

**What it means:** checkouts (`POST /api/payment/pay/<user>`) are failing
with 5xx errors faster than the 99% SLO allows. A fast burn means the week's
error budget runs out in under 12 hours.

**First goal:** get checkouts working again. Find the full cause later, in
the postmortem.

---

## 0. Open the tools

Each command goes in its own terminal tab:

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80   # http://localhost:3000
kubectl port-forward -n tracing svc/jaeger 16686:16686              # http://localhost:16686
```

## 1. How bad is it? (2 minutes)

Grafana > **Robot Shop - Requests, Errors, Latency**:

- Top row: **burn rate** and **budget left**.
- **Error rate (5xx) by service**: is it only payment, or everything?
  - **Everything is failing:** the problem is the gateway, the cluster or a
    node. Go to step 4.
  - **Only payment:** continue.
- **Requests per second by status code**: are there still 200s? A few failing
  checkouts is a different problem from all of them failing.

## 2. Is payment running?

```bash
kubectl get pods -n robot-shop -l service=payment
kubectl describe pod -n robot-shop -l service=payment | tail -20
```

| You see | Likely cause | Do |
|---|---|---|
| `CrashLoopBackOff` / restarts climbing | payment crashes on start | `kubectl logs -n robot-shop deploy/payment --previous` |
| `OOMKilled` in describe | out of memory | raise `payment.resources.limits.memory` in `K8s/helm/values-eks.yaml`, redeploy |
| `ImagePullBackOff` | image tag missing, or the GHCR package went private | check `payment.image`; GitHub > Packages > rs-payment must be **Public** |
| `Running`, no restarts | payment is up but its requests fail | step 3 |

## 3. What error? (logs, then traces)

**Logs:** Grafana > Explore > Loki:

```
{namespace="robot-shop", service="payment", level="error"}
```

Each payment log line has a `trace_id`. Click a line, then **View trace in
Jaeger**.

**Traces:** Jaeger > Service `payment` > Find Traces. Failed checkouts have a
red mark; open one and see which step is red:

| Red step in the trace | Meaning | Do |
|---|---|---|
| Only `POST /pay/<id>`, with 2 spans in total | payment crashed in its own code before calling anything | read the error in the logs, step 3a |
| `GET` to the payment gateway | the outside gateway is failing | step 3b |
| `robot-shop send` (RabbitMQ) red, then a second one OK | RabbitMQ dropped an idle connection and payment reconnected. The checkout still succeeded | no action; known issue, see the postmortem |
| `robot-shop send` red with no retry after it | RabbitMQ is down | `kubectl get pods -n robot-shop -l service=rabbitmq` |
| `GET 404` on `user:8080/check/...` | normal: a guest checkout (the user isn't registered). OpenTelemetry marks every 4xx red | not a problem |

### 3a. payment crashes on a request

The most likely cause, and the one this SLO found on day one:
`'NoneType' object is not iterable` on `/pay/partner-57`.

1. Search the logs for the message:
   ```
   {namespace="robot-shop", service="payment"} |= "NoneType"
   ```
2. The trace shows the request body was a cart with no `items`. payment
   loops over `cart.get('items')`, gets `None`, and crashes with a 500.
3. **Fix:** reject a cart with no items with **400** ("cart not valid").
   Bad input is the client's fault, and a 4xx doesn't spend the error budget.
4. Ship the fix (see "Shipping a payment fix" below). Within about 5
   minutes the 5-minute burn rate falls and the alert resolves.

If it's a different error: if a recent payment change caused it, roll back
(below); otherwise fix forward.

### 3b. the payment gateway fails or is slow

The gateway is outside the cluster (`PAYMENT_GATEWAY`, default PayPal). There
is nothing to restart. Confirm it from inside the cluster:

```bash
kubectl run gwtest -n robot-shop --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://www.paypal.com/
```

Note the time in the incident channel. The error budget policy says a
gateway outage is recorded but doesn't freeze our own work.

## 4. Everything is failing

```bash
kubectl get nodes
kubectl get pods -n robot-shop
kubectl top nodes        # needs metrics-server; skip if it isn't installed
```

A node that is `NotReady`, or many pods `Pending`, is a cluster problem.
Check the AWS console (EC2 instances, EKS node group) for the cluster
`Uga-vote-cluster` in `eu-north-1`.

## Checkouts are slow

`CheckoutLatencyBudgetFastBurn`: more than 30% of checkouts took over
1 second in the last hour.

1. Jaeger > Service `payment` > **Min Duration `1s`** > Find Traces.
2. Open one. The longest bar is the cause. On 28 Oct 2026 a normal checkout
   spent 239 of its 258 ms waiting for the payment gateway.
3. If it's the gateway, use 3b. If it's `user` or `cart`, check those pods and
   their entries on the Requests/Errors/Latency dashboard.

---

## Rolling back payment

```bash
helm history robot-shop -n robot-shop
helm rollback robot-shop <last good revision> -n robot-shop --wait
```

## Shipping a payment fix

1. Change `payment/`. Bump `PAYMENT_VERSION` in
   `.github/workflows/payment-image.yml` **and** `payment.image` in
   `K8s/helm/values-eks.yaml` to the same new tag.
2. Open a PR. CI builds and smoke-tests the image. Merge it; the
   *payment image* workflow pushes it to GHCR.
3. `./scripts/deploy-shop.sh`

## Afterwards

- Write down in the incident channel when it started, when it was noticed,
  and when it was fixed.
- If the incident used more than 20% of the week's budget, or the budget is
  used up: blameless postmortem (`docs/postmortems/`), and the feature freeze
  from the error budget policy applies.
