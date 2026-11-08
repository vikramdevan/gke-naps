#!/usr/bin/env bash
# ==============================================================================
# Script Name: 06-toggle-workload.sh
# Description: Toggles workloads via Helm flags to trigger specific GKE NAP
#              auto-provisioning scenarios:
#                --cpu   : Deploys baseline + high-CPU workload (triggers NAP dynamic node pool)
#                --spot  : Deploys baseline + Spot VM workload (triggers NAP Spot node pool)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART="${SCRIPT_DIR}/../charts/gke-naps-demo"

# Colors for terminal output
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

print_usage() {
    local exit_code="${1:-0}"
    echo -e "${CYAN}Usage:${NC} ./scripts/06-toggle-workload.sh [FLAG]"
    echo ""
    echo "Options (specify exactly one):"
    echo -e "  ${YELLOW}--cpu${NC}    Enable baseline + high-CPU workload (3000m CPU)"
    echo -e "  ${YELLOW}--spot${NC}   Enable baseline + Spot VM workload (Spot label/toleration)"
    echo -e "  ${YELLOW}-h, --help${NC} Show this help menu"
    echo ""
    echo "Examples:"
    echo "  ./scripts/06-toggle-workload.sh --cpu"
    echo "  ./scripts/06-toggle-workload.sh --spot"
    exit "$exit_code"
}

# Ensure helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm is not installed or not in PATH.${NC}" >&2
    exit 1
fi

# Ensure at least one argument was passed
if [ "$#" -eq 0 ]; then
    echo -e "${RED}Error: No flag provided.${NC}"
    print_usage 1
fi

case "$1" in
    --cpu)
        echo -e "${GREEN}>>> Applying Workload: Baseline + High-CPU (NAP dynamic node pool trigger)...${NC}"
        helm upgrade naps-demo "${HELM_CHART}" \
            --set baselineWorkload.enabled=true \
            --set cpuWorkload.enabled=true \
            --set taintedWorkload.enabled=false \
            --set spotWorkload.enabled=false
        echo -e "${GREEN}✓ Successfully applied High-CPU workload configuration.${NC}"
        ;;
    --spot)
        echo -e "${GREEN}>>> Applying Workload: Baseline + Spot VM (NAP Spot node pool trigger)...${NC}"
        helm upgrade naps-demo "${HELM_CHART}" \
            --set baselineWorkload.enabled=true \
            --set cpuWorkload.enabled=false \
            --set taintedWorkload.enabled=false \
            --set spotWorkload.enabled=true
        echo -e "${GREEN}✓ Successfully applied Spot VM workload configuration.${NC}"
        ;;
    -h|--help)
        print_usage 0
        ;;
    *)
        echo -e "${RED}Error: Unknown flag '$1'${NC}"
        print_usage 1
        ;;
esac
