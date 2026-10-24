#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${DIR}/infra/cluster-config.yaml"
DNS_CONFIG_FILE="${DIR}/infra/kube-dns-config.yaml"
CLUSTER_NAME="naps-demo-cluster"
PROJECT_ID="gke-naps"
ZONE="us-central1-a"

echo "=================================================="
echo " Provisioning GKE Infrastructure from YAML Spec"
echo " Config file:  ${CONFIG_FILE}"
echo " Cluster:      ${CLUSTER_NAME}"
echo "=================================================="

# Ensure gcloud is pointing to the right project
gcloud config set project "${PROJECT_ID}"

echo ""
echo ">>> Checking if cluster already exists..."
if gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "Cluster '${CLUSTER_NAME}' already exists."
else
    echo ">>> Creating GKE cluster using declarative YAML configuration..."
    gcloud container clusters create "${CLUSTER_NAME}" \
        --flags-file="${CONFIG_FILE}"
fi

echo ""
echo ">>> Fetching cluster credentials for kubectl / Helm..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

echo ""
echo ">>> Applying single-replica kube-dns configuration..."
# Prevents kube-dns from scheduling onto dynamic NAP nodes and blocking their scale-down/deletion
kubectl apply -f "${DNS_CONFIG_FILE}"
kubectl scale deployment kube-dns -n kube-system --replicas=1 || true

echo ""
echo ">>> Cluster setup complete!"
echo "Current node pools:"
gcloud container node-pools list --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"
