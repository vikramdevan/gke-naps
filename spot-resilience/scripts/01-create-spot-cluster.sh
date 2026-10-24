#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${DIR}/infra/spot-cluster-config.yaml"
DNS_CONFIG_FILE="${DIR}/infra/kube-dns-config.yaml"
CLUSTER_NAME="spot-demo-cluster"
PROJECT_ID="gke-naps"
ZONE="us-central1-c"

echo "=========================================================="
echo " Provisioning GKE Spot Resilience Demo Cluster"
echo " Project:      ${PROJECT_ID}"
echo " Cluster:      ${CLUSTER_NAME}"
echo " Zone:         ${ZONE}"
echo " Config:       ${CONFIG_FILE}"
echo "=========================================================="

# Ensure gcloud is pointing to the right project
gcloud config set project "${PROJECT_ID}"

echo ""
echo ">>> Checking if cluster '${CLUSTER_NAME}' already exists..."
if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "Cluster '${CLUSTER_NAME}' is already running."
else
    echo ">>> Creating GKE Spot cluster (2x e2-medium Spot nodes, cost < \$0.03/hr)..."
    gcloud container clusters create "${CLUSTER_NAME}" \
        --flags-file="${CONFIG_FILE}"
fi

echo ""
echo ">>> Downloading credentials for kubectl / Helm..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

echo ""
echo ">>> Applying single-replica kube-dns configuration to keep DNS stable..."
kubectl apply -f "${DNS_CONFIG_FILE}"
kubectl scale deployment kube-dns -n kube-system --replicas=1 || true

echo ""
echo ">>> Cluster setup complete!"
echo "Current Spot nodes:"
kubectl get nodes -o wide --show-labels | grep -E "NAME|cloud.google.com/gke-spot"
