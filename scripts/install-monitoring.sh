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

for tool in kubectl helm openssl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed"; exit 1; }
done

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "== Grafana admin password =="
# created once with a random value and never stored in Git; re-runs keep it
if ! kubectl get secret grafana-admin -n "$NS" >/dev/null 2>&1; then
    kubectl create secret generic grafana-admin -n "$NS" \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$(openssl rand -base64 18)"
    echo "created secret grafana-admin"
else
    echo "secret grafana-admin already exists, keeping it"
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
