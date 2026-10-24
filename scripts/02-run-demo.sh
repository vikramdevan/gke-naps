#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="gke-naps"
CLUSTER_NAME="naps-demo-cluster"
ZONE="us-central1-c"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM_CHART="${DIR}/charts/gke-naps-demo"

echo "=========================================================="
echo " GKE Node Auto-Provisioning (NAP) Interactive Helm Demo"
echo "=========================================================="

echo ""
echo "--- STEP 1: Verify Current Initial State ---"
echo "Listing node pools in cluster:"
gcloud container node-pools list --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

echo ""
echo "Listing Kubernetes nodes:"
kubectl get nodes -o wide

echo ""
echo "--- STEP 2: Deploy Baseline Workload via Helm ---"
echo "Installing Helm chart with only baseline workload enabled..."
helm upgrade --install naps-demo "${HELM_CHART}" \
    --set baselineWorkload.enabled=true \
    --set cpuWorkload.enabled=false \
    --set taintedWorkload.enabled=false \
    --set spotWorkload.enabled=false \
    --wait --timeout=90s

echo ""
echo "Baseline app successfully running on default node pool:"
kubectl get pods -o wide -l app.kubernetes.io/component=baseline-workload

echo ""
echo "--- STEP 3: Trigger Node Auto-Provisioning (NAP) via Helm ---"
echo "Upgrading Helm release to enable high-CPU workload (demands 3 vCPUs, cannot fit on default node)..."
helm upgrade naps-demo "${HELM_CHART}" \
    --set baselineWorkload.enabled=true \
    --set cpuWorkload.enabled=true \
    --set taintedWorkload.enabled=false \
    --set spotWorkload.enabled=false

echo ""
echo "Checking initial pod state (should be Pending):"
kubectl get pods -l app.kubernetes.io/component=cpu-workload

echo ""
echo ">>> Node Auto-Provisioner has detected the pending unschedulable pod."
echo ">>> GKE is dynamically creating a new node pool tailored to this workload..."
echo "Waiting for dynamic node pool creation and pod scheduling..."
echo "(This typically takes ~1.5 to 2.5 minutes for GKE to provision the new node pool)"

# Poll until the new node pool appears
for i in {1..30}; do
    POOLS=$(gcloud container node-pools list --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --format="value(name)" | grep "^nap-" || true)
    if [ -n "${POOLS}" ]; then
        echo ""
        echo ">>> SUCCESS! Auto-provisioned node pool detected: ${POOLS}"
        break
    fi
    echo -n "."
    sleep 5
done

echo ""
echo "Current Node Pools in GKE:"
gcloud container node-pools list --cluster="${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"

echo ""
echo "Waiting for the workload pod to become Running on the new node..."
kubectl rollout status deployment/naps-demo-gke-naps-demo-cpu-workload --timeout=180s

echo ""
echo "All Workload Pods and their assigned nodes:"
kubectl get pods -o wide

echo ""
echo "=========================================================="
echo " Demo completed successfully!"
echo " A new node pool was dynamically provisioned by GKE NAP"
echo " using declarative YAML and Helm!"
echo "=========================================================="
