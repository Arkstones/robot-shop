#!/usr/bin/env bash
# scripts/install-logging.sh - logs for Robot Shop: Loki + Fluent Bit + Grafana.
#
# Usage: ./scripts/install-logging.sh
#
# Run after ./scripts/install-monitoring.sh (it needs Grafana and the
# ServiceMonitor type from kube-prometheus-stack).
#
#   Fluent Bit (one pod per node) --reads--> container log files
#              --sends--> Loki (namespace "logging") <--searches-- Grafana
#
# Safe to run again: everything is install-or-update.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=logging
LOKI_CHART_VERSION=20.0.2        # Loki 3.7
FLUENT_BIT_CHART_VERSION=0.58.3  # Fluent Bit 5.1
CONF="$ROOT_DIR/observability/logging"

for tool in kubectl helm; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed"; exit 1; }
done

if ! kubectl get deploy monitoring-grafana -n monitoring >/dev/null 2>&1; then
    echo "ERROR: Grafana isn't installed yet. Run ./scripts/install-monitoring.sh first."
    exit 1
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Loki's chart moved from grafana/helm-charts to the community repo in 2026
helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana-community fluent >/dev/null

echo "== Loki $LOKI_CHART_VERSION (stores the logs) =="
helm upgrade --install loki grafana-community/loki \
    --version "$LOKI_CHART_VERSION" \
    --namespace "$NS" \
    -f "$CONF/loki-values.yaml" \
    --wait --timeout 10m

echo
echo "== Fluent Bit $FLUENT_BIT_CHART_VERSION (collects them on every node) =="
helm upgrade --install fluent-bit fluent/fluent-bit \
    --version "$FLUENT_BIT_CHART_VERSION" \
    --namespace "$NS" \
    -f "$CONF/fluent-bit-values.yaml" \
    --set-file 'luaScripts.shape-log\.lua'="$CONF/shape-log.lua" \
    --wait --timeout 10m

echo
echo "== Grafana: Loki data source and logs dashboard =="
kubectl apply -f "$CONF/grafana-loki-datasource.yaml"
kubectl create configmap robot-shop-logs-dashboard -n monitoring \
    --from-file="$ROOT_DIR/observability/dashboards/robot-shop-logs.json" \
    --dry-run=client -o yaml |
    kubectl label --local -f - grafana_dashboard=1 -o yaml |
    kubectl apply -f -

echo
kubectl get pods -n "$NS" -o wide
echo
echo "Check that logs arrive (give it a minute):"
echo "  kubectl port-forward -n $NS svc/loki 3100:3100 >/dev/null &"
echo "  sleep 3; curl -s localhost:3100/loki/api/v1/label/service/values; echo"
echo "  kill %1"
echo
echo "Then in Grafana: Dashboards > Robot Shop - Logs, or Explore > Loki with"
echo '  {namespace="robot-shop", service="payment", level="error"}'
