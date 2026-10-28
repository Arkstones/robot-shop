#!/usr/bin/env bash
# scripts/install-monitoring.sh - Prometheus, Alertmanager and Grafana for Robot Shop.
#
# Usage: ./scripts/install-monitoring.sh
#
# Installs kube-prometheus-stack into the "monitoring" namespace, tells
# Prometheus what to scrape in robot-shop, and loads my dashboard into Grafana.
# Safe to run again: everything is install-or-update.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=monitoring
CHART_VERSION=92.14.1

for tool in kubectl helm base64 head; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed"; exit 1; }
done

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "== Grafana admin password =="
# 24 random letters/digits straight from the kernel's random source
# (no openssl needed, which can be broken on some machines)
new_password() {
    head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-24
}

# created once and never stored in Git; re-runs keep it, unless it is
# missing or empty (an earlier version of this script could save an empty one)
current=$(kubectl get secret grafana-admin -n "$NS" -o jsonpath='{.data.admin-password}' 2>/dev/null || true)
if [[ -n "$current" ]]; then
    echo "secret grafana-admin already exists, keeping it"
else
    password=$(new_password)
    if (( ${#password} < 20 )); then
        echo "ERROR: could not generate a Grafana password" >&2
        exit 1
    fi
    kubectl create secret generic grafana-admin -n "$NS" \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$password" \
        --dry-run=client -o yaml | kubectl apply -f -
    unset password
    echo "created secret grafana-admin"
    # Grafana only reads the password when it starts
    if kubectl get deploy monitoring-grafana -n "$NS" >/dev/null 2>&1; then
        kubectl rollout restart deploy/monitoring-grafana -n "$NS"
    fi
fi

echo
echo "== Slack webhook for alerts =="
# Alertmanager reads the webhook URL from this Secret (see alertmanager: in
# kube-prometheus-stack-values.yaml). The URL is a password: anyone who has
# it can post to the channel, so it is typed in here and never stored in Git
# or in shell history. To change it later:
#   kubectl delete secret alertmanager-slack -n monitoring && ./scripts/install-monitoring.sh
if kubectl get secret alertmanager-slack -n "$NS" >/dev/null 2>&1; then
    echo "secret alertmanager-slack already exists, keeping it"
else
    webhook="${SLACK_WEBHOOK_URL:-}"
    if [[ -z "$webhook" && -t 0 ]]; then
        read -rsp "Paste the Slack incoming-webhook URL (input hidden, Enter to skip): " webhook
        echo
    fi
    if [[ "$webhook" != https://hooks.slack.com/* ]]; then
        echo "WARNING: no valid Slack webhook given; alerts will fire but not reach Slack."
        echo "         Re-run this script after deleting the secret to add one."
        webhook="https://hooks.slack.com/services/NOT/CONFIGURED/YET"
    fi
    kubectl create secret generic alertmanager-slack -n "$NS" \
        --from-literal=webhook-url="$webhook" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    unset webhook
    echo "created secret alertmanager-slack"
fi

echo
echo "== kube-prometheus-stack $CHART_VERSION =="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --version "$CHART_VERSION" \
    --namespace "$NS" \
    -f "$ROOT_DIR/observability/kube-prometheus-stack-values.yaml" \
    --wait --timeout 15m

echo
echo "== what Prometheus scrapes in robot-shop =="
kubectl apply -f "$ROOT_DIR/observability/servicemonitors.yaml"

echo
echo "== checkout SLO: recording rules and burn-rate alerts =="
# docs/slo/checkout.md explains the numbers
kubectl apply -f "$ROOT_DIR/observability/slo/checkout-slo-rules.yaml"

echo
echo "== dashboard (dashboard as code) =="
# the JSON in Git is the source; this wraps it in a ConfigMap that the
# Grafana sidecar watches (label grafana_dashboard=1)
kubectl create configmap robot-shop-red-dashboard -n "$NS" \
    --from-file="$ROOT_DIR/observability/dashboards/robot-shop-red.json" \
    --dry-run=client -o yaml |
    kubectl label --local -f - grafana_dashboard=1 -o yaml |
    kubectl apply -f -

echo
kubectl get pods -n "$NS"
echo
echo "Open Grafana:"
echo "  kubectl port-forward -n $NS svc/monitoring-grafana 3000:80"
echo "  then http://localhost:3000  (user: admin)"
echo "Password:"
echo "  kubectl get secret grafana-admin -n $NS -o jsonpath='{.data.admin-password}' | base64 -d; echo"
