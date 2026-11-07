#!/usr/bin/env bash
# ==============================================================================
# Script Name: cluster-inspect.sh
# Description: Displays GKE/Kubernetes cluster configuration, NAP settings, 
#              node pools, node specs (resources, taints, spot status), and 
#              pods specifically in the 'default' namespace grouped by node.
# ==============================================================================

set -eo pipefail

# Check for kubectl availability
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH." >&2
    exit 1
fi

# Colors for output readability
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${CYAN}==============================================================================${NC}"
    echo -e "${CYAN} $1 ${NC}"
    echo -e "${CYAN}==============================================================================${NC}"
}

print_subheader() {
    echo -e "\n${GREEN}--- $1 ---${NC}"
}

# ------------------------------------------------------------------------------
# 1. CLUSTER & NAP CONFIGURATION
# ------------------------------------------------------------------------------
print_header "1. CLUSTER & NODE AUTO-PROVISIONING (NAP) CONFIGURATION"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "Unknown")
print_subheader "Active Kubernetes Context"
echo "Context: $CURRENT_CONTEXT"

# If gcloud is available and it's a GKE cluster, query GKE-specific NAP settings
if command -v gcloud &> /dev/null; then
    GKE_CLUSTER=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true)
    
    if [[ "$GKE_CLUSTER" == gke_* ]]; then
        # Parse gke_PROJECT_LOCATION_CLUSTER
        IFS='_' read -r _ GCP_PROJECT GCP_LOCATION GCP_CLUSTER_NAME <<< "$GKE_CLUSTER"
        
        print_subheader "GKE Cluster NAP (Autopilot / Node Auto-Provisioning) Details"
        gcloud container clusters describe "$GCP_CLUSTER_NAME" \
            --project="$GCP_PROJECT" \
            --location="$GCP_LOCATION" \
            --format="yaml(autoscaling,nodePoolAutoConfig)" 2>/dev/null || echo "Could not fetch NAP details via gcloud (permissions or standard k8s cluster)."
    else
        echo "Note: Current context is not a standard GKE naming format. Skipping gcloud NAP query."
    fi
else
    echo "gcloud CLI not found. Skipping direct GKE NAP cloud provider query."
fi

# ------------------------------------------------------------------------------
# 2. NODE POOLS
# ------------------------------------------------------------------------------
print_header "2. NODE POOLS"
print_subheader "Listing Node Pools in Cluster"
if command -v gcloud &> /dev/null && [[ "$GKE_CLUSTER" == gke_* ]]; then
    gcloud container node-pools list \
        --cluster="$GCP_CLUSTER_NAME" \
        --project="$GCP_PROJECT" \
        --location="$GCP_LOCATION"
else
    # Fallback to checking node pool labels from kubernetes nodes
    kubectl get nodes -o custom-columns='NAME:.metadata.name,NODE-POOL:.metadata.labels.cloud\.google\.com/gke-nodepool,OS:.status.nodeInfo.osImage'
fi

# ------------------------------------------------------------------------------
# 3. NODES (Resources, Taints, Spot/Preemptible Status)
# ------------------------------------------------------------------------------
print_header "3. NODES CONFIGURATION"
print_subheader "Node Capacity, Machine Type, and Spot/Preemptible Annotations"

printf "%-25s | %-15s | %-8s | %-8s | %-12s\n" "NODE NAME" "MACHINE TYPE" "vCPU" "MEM (Gi)" "SPOT / TYPE"
echo "--------------------------------------------------------------------------------"

for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    MACHINE_TYPE=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
    [ -z "$MACHINE_TYPE" ] && MACHINE_TYPE=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
    [ -z "$MACHINE_TYPE" ] && MACHINE_TYPE="unknown"

    CPU=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')
    MEM_RAW=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}')
    
    MEM_KI=${MEM_RAW%Ki}
    MEM_GI=$((MEM_KI / 1024 / 1024))

    SPOT_LABEL=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-spot}')
    PREEMP_LABEL=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-preemptible}')
    
    NODE_TYPE="Standard"
    if [ "$SPOT_LABEL" == "true" ]; then
        NODE_TYPE="${YELLOW}Spot${NC}"
    elif [ "$PREEMP_LABEL" == "true" ]; then
        NODE_TYPE="${YELLOW}Preemptible${NC}"
    fi

    printf "%-25s | %-15s | %-8s | %-8s | %-12s\n" "$node" "$MACHINE_TYPE" "$CPU" "${MEM_GI}Gi" "$NODE_TYPE"
done

print_subheader "Node Taints"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'

# ------------------------------------------------------------------------------
# 4. PODS IN 'default' NAMESPACE (Grouped by Node)
# ------------------------------------------------------------------------------
print_header "4. PODS IN 'default' NAMESPACE (Grouped by Node)"

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

for node in $NODES; do
    print_subheader "Node: $node"
    
    printf "%-35s | %-15s\n" "POD NAME" "STATUS"
    echo "----------------------------------------------------"
    
    # Query only pods in the 'default' namespace assigned to this node
    POD_DATA=$(kubectl get pods -n default --field-selector="spec.nodeName=$node" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
    
    if [ -z "$POD_DATA" ]; then
        echo "(No pods running in 'default' namespace on this node)"
    else
        while IFS=$'\t' read -r pod status; do
            [ -n "$pod" ] && printf "%-35s | %-15s\n" "$pod" "$status"
        done <<< "$POD_DATA"
    fi
    echo ""
done

print_header "Inspection Complete"