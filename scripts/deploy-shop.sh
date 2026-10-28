#!/usr/bin/env bash
# scripts/deploy-shop.sh - install or upgrade Robot Shop on the EKS cluster.
#
# Usage: ./scripts/deploy-shop.sh
#
# Needs kubectl and helm pointed at the cluster. The cluster comes from the
# Capstone 1 repo:  NODE_COUNT=3 ./terraform/up.sh  (in example-voting-app)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=robot-shop

for tool in kubectl helm; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is not installed"; exit 1; }
done

echo "== cluster =="
kubectl config current-context
kubectl get nodes

echo
echo "== installing Robot Shop into namespace $NS =="
helm upgrade --install robot-shop "$ROOT_DIR/K8s/helm" \
    --namespace "$NS" --create-namespace \
    -f "$ROOT_DIR/K8s/helm/values-eks.yaml" \
    --wait --timeout 15m

echo
echo "== pods =="
kubectl get pods -n "$NS" -o wide

echo
host=$(kubectl get svc web -n "$NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Shop: http://$host:8080"
echo "(a new load balancer can take 2-3 minutes before the URL answers)"
