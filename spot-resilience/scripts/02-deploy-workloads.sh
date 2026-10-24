#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${DIR}/charts/spot-preemption-demo"
RELEASE_NAME="spot-demo"

echo "=========================================================="
echo " Deploying Resilient Workload & Traffic Generator"
echo " Release:      ${RELEASE_NAME}"
echo " Chart:        ${CHART_DIR}"
echo "=========================================================="

echo ">>> Installing / Upgrading Helm release '${RELEASE_NAME}'..."
helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" --wait --timeout=120s

echo ""
echo ">>> Checking deployed workloads:"
kubectl get deployments,services,pdb

echo ""
echo ">>> Checking Pod placement across Spot nodes:"
kubectl get pods -o wide -l app.kubernetes.io/component=resilient-web

echo ""
echo ">>> Workloads successfully deployed!"
echo "Notice that replicas are distributed across different Spot nodes due to topologySpreadConstraints."
