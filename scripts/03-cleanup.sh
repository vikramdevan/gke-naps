#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="gke-naps"
CLUSTER_NAME="naps-demo-cluster"
ZONE="us-central1-c"

echo "=========================================================="
echo " Cleanup GKE Node Auto-Provisioning Resources"
echo "=========================================================="

echo ">>> Uninstalling Helm release 'naps-demo'..."
helm uninstall naps-demo || true

echo ""
read -p "Do you also want to delete the GKE cluster '${CLUSTER_NAME}' to prevent any ongoing charges? (y/N): " -n 1 -r
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
