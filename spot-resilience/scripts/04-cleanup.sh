#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="spot-demo-cluster"
ZONE="us-central1-c"
PROJECT_ID="gke-naps"
RELEASE_NAME="spot-demo"

echo "=========================================================="
echo " Cleaning Up GKE Spot Resilience Demo Resources"
echo "=========================================================="

echo ">>> Uninstalling Helm release '${RELEASE_NAME}'..."
helm uninstall "${RELEASE_NAME}" 2>/dev/null || true

echo ""
read -p "Do you also want to delete the GKE cluster '${CLUSTER_NAME}' to prevent ongoing charges? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ">>> Deleting GKE cluster '${CLUSTER_NAME}'..."
    gcloud container clusters delete "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "Cluster deleted successfully."
else
    echo "Cluster retained. Remember to delete it later via:"
    echo "  gcloud container clusters delete ${CLUSTER_NAME} --zone=${ZONE} --project=${PROJECT_ID}"
fi
