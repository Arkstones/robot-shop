#!/usr/bin/env bash
# scripts/install-tracing.sh - traces for Robot Shop: OpenTelemetry Collector + Jaeger.
#
# Usage: ./scripts/install-tracing.sh
#
# Run after install-monitoring.sh and install-logging.sh (it adds Jaeger to
# the same Grafana, and links Loki log lines to traces). Then run
# ./scripts/deploy-shop.sh so payment starts sending traces.
#
#   payment --OTLP--> otel-collector --OTLP--> Jaeger <--searches-- Grafana / Jaeger UI
#
# Safe to run again: everything is install-or-update.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=tracing
COLLECTOR_CHART_VERSION=0.178.0   # collector 0.163
CONF="$ROOT_DIR/observability/tracing"

for tool in kubectl helm; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed"; exit 1; }
done

if ! kubectl get deploy monitoring-grafana -n monitoring >/dev/null 2>&1; then
    echo "ERROR: Grafana isn't installed yet. Run ./scripts/install-monitoring.sh first."
    exit 1
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "== Jaeger (stores and shows traces) =="
kubectl apply -f "$CONF/jaeger.yaml"
kubectl rollout status deploy/jaeger -n "$NS" --timeout=5m

echo
echo "== OpenTelemetry Collector $COLLECTOR_CHART_VERSION (receives traces, sends them to Jaeger) =="
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
    --version "$COLLECTOR_CHART_VERSION" \
    --namespace "$NS" \
    -f "$CONF/otel-collector-values.yaml" \
    --wait --timeout 10m

echo
echo "== Grafana: Jaeger data source, Loki log lines linked to traces =="
kubectl apply -f "$CONF/grafana-jaeger-datasource.yaml"
kubectl apply -f "$ROOT_DIR/observability/logging/grafana-loki-datasource.yaml"

echo
kubectl get pods -n "$NS"
echo
echo "Next: ./scripts/deploy-shop.sh  (switches payment to the traced image)"
echo
echo "Then open Jaeger:"
echo "  kubectl port-forward -n $NS svc/jaeger 16686:16686"
echo "  http://localhost:16686  -> Service: payment -> Find Traces"
