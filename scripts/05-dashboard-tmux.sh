#!/usr/bin/env bash
# ==============================================================================
# Script Name: 05-dashboard-tmux.sh
# Description: Launches a multi-pane tmux live dashboard for GKE NAP demo.
#              Each pane refreshes independently without redrawing the entire screen:
#                - Top-Left:  Cluster context & NAP auto-provisioning config
#                - Top-Right: Live Node status & specs (Machine type, Spot, vCPU/Mem)
#                - Bottom-Left: Live Pods in 'default' namespace (linked to nodes)
#                - Bottom-Right: Pending / Unscheduled pods (waiting on NAP scaling)
#
# Note: Uses native bash while-loops for polling so it does NOT depend on the
#       Linux 'watch' utility (which is not installed by default on macOS).
# ==============================================================================

set -eo pipefail

SESSION_NAME="gke-nap-dashboard"

# Ensure tmux and kubectl are installed
if ! command -v tmux &> /dev/null; then
    echo "Error: tmux is not installed. Please install it (e.g. 'brew install tmux')." >&2
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH." >&2
    exit 1
fi

# If existing session exists, kill it cleanly so fresh panes can be initialized
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Recreating existing tmux session '$SESSION_NAME'..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
fi

# Top-Left Pane: Cluster & NAP configuration
CMD_NAP_INFO='bash -c "
while true; do
    clear;
    echo \"=== CLUSTER & NAP CONFIGURATION (Every 5s) ===\";
    echo \"Context: \$(kubectl config current-context 2>/dev/null || echo Unknown)\";
    echo \"\";
    GKE_CLUSTER=\$(kubectl config view --minify -o jsonpath=\"{.contexts[0].context.cluster}\" 2>/dev/null || true);
    if [[ \"\$GKE_CLUSTER\" == gke_* ]] && command -v gcloud &> /dev/null; then
        IFS=\"_\" read -r _ GCP_PROJECT GCP_LOCATION GCP_CLUSTER_NAME <<< \"\$GKE_CLUSTER\";
        echo \"Project: \$GCP_PROJECT | Cluster: \$GCP_CLUSTER_NAME\";
        echo \"\";
        echo \"--- NAP Auto-Provisioning Settings ---\";
        gcloud container clusters describe \"\$GCP_CLUSTER_NAME\" \
            --project=\"\$GCP_PROJECT\" \
            --location=\"\$GCP_LOCATION\" \
            --format=\"yaml(autoscaling,nodePoolAutoConfig)\" 2>/dev/null || echo \"Unable to query NAP settings.\";
    else
        echo \"Active context is not standard GKE format or gcloud not found.\";
    fi;
    echo \"\";
    echo \"[Press Ctrl+b then d to detach]\";
    sleep 600;
done
"'

# Top-Right Pane: Live Node Pools, Nodes & Specs
CMD_NODES='bash -c "
while true; do
    clear;
    echo \"=== [A] GKE NODE POOLS ===\";
    GKE_CLUSTER=\$(kubectl config view --minify -o jsonpath=\"{.contexts[0].context.cluster}\" 2>/dev/null || true);
    if [[ \"\$GKE_CLUSTER\" == gke_* ]] && command -v gcloud &> /dev/null; then
        IFS=\"_\" read -r _ GCP_PROJECT GCP_LOCATION GCP_CLUSTER_NAME <<< \"\$GKE_CLUSTER\";
        POOLS_OUT=\$(gcloud container node-pools list --cluster=\"\$GCP_CLUSTER_NAME\" --project=\"\$GCP_PROJECT\" --location=\"\$GCP_LOCATION\" 2>/dev/null || true);
        if [ -n \"\$POOLS_OUT\" ]; then
            echo \"\$POOLS_OUT\" | head -n 1;
            echo \"------------------------------------------------------------------------------------------------\";
            echo \"\$POOLS_OUT\" | tail -n +2;
        else
            kubectl get nodes -o custom-columns=\"NODE-POOL:.metadata.labels.cloud\.google\.com/gke-nodepool,NODE:.metadata.name\" 2>/dev/null;
        fi;
    else
        POOLS_OUT=\$(kubectl get nodes -o custom-columns=\"NODE-POOL:.metadata.labels.cloud\.google\.com/gke-nodepool,NODE:.metadata.name\" 2>/dev/null || true);
        echo \"\$POOLS_OUT\" | head -n 1;
        echo \"------------------------------------------------------------------------------------------------\";
        echo \"\$POOLS_OUT\" | tail -n +2;
    fi;
    echo \"\";
    echo \"=== [B] LIVE NODES & HARDWARE SPECS ===\";
    printf \"%-24s | %-16s | %-12s | %-6s | %-8s | %-6s\n\" \"NODE NAME\" \"NODE POOL\" \"TYPE\" \"vCPU\" \"MEM (Gi)\" \"SPOT\";
    echo \"------------------------------------------------------------------------------------------------\";
    for n in \$(kubectl get nodes -o jsonpath=\"{.items[*].metadata.name}\" 2>/dev/null); do
        POOL=\$(kubectl get node \$n -o jsonpath=\"{.metadata.labels.cloud\.google\.com/gke-nodepool}\" 2>/dev/null);
        [ -z \"\$POOL\" ] && POOL=\"default\";
        MT=\$(kubectl get node \$n -o jsonpath=\"{.metadata.labels.node\.kubernetes\.io/instance-type}\" 2>/dev/null);
        [ -z \"\$MT\" ] && MT=\$(kubectl get node \$n -o jsonpath=\"{.metadata.labels.beta\.kubernetes\.io/instance-type}\" 2>/dev/null);
        [ -z \"\$MT\" ] && MT=\"unknown\";
        CPU=\$(kubectl get node \$n -o jsonpath=\"{.status.capacity.cpu}\" 2>/dev/null);
        MEM_RAW=\$(kubectl get node \$n -o jsonpath=\"{.status.capacity.memory}\" 2>/dev/null);
        MEM_KI=\${MEM_RAW%Ki};
        MEM_GI=\$((MEM_KI / 1024 / 1024));
        SPOT=\$(kubectl get node \$n -o jsonpath=\"{.metadata.labels.cloud\.google\.com/gke-spot}\" 2>/dev/null);
        [ \"\$SPOT\" != \"true\" ] && SPOT=\"false\";
        printf \"%-24s | %-16s | %-12s | %-6s | %-8s | %-6s\n\" \"\$n\" \"\$POOL\" \"\$MT\" \"\$CPU\" \"\${MEM_GI}Gi\" \"\$SPOT\";
    done;
    echo \"\";
    echo \"--- Node Taints ---\";
    kubectl get nodes -o custom-columns=\"NODE:.metadata.name,TAINTS:.spec.taints[*].key\" 2>/dev/null | awk \"NR==1{print; print \\\"------------------------------------------------------------------------------------------------\\\"} NR>1{print}\";
    sleep 30;
done
"'

# Bottom-Left Pane: Live Pods in 'default' namespace
CMD_DEFAULT_PODS='bash -c "
while true; do
    clear;
    echo \"=== LIVE PODS IN DEFAULT NAMESPACE ===\";
    PODS_OUT=\$(kubectl get pods -n default -o custom-columns=\"NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName,AGE:.metadata.creationTimestamp\" 2>/dev/null || true);
    if [ -n \"\$PODS_OUT\" ]; then
        echo \"\$PODS_OUT\" | head -n 1;
        echo \"------------------------------------------------------------------------------------------------\";
        echo \"\$PODS_OUT\" | tail -n +2;
    else
        echo \"No pods found in default namespace\";
    fi;
    sleep 15;
done
"'

# Bottom-Right Pane: Pending / Unscheduled Pods (Excluding kube-system)
CMD_PENDING_PODS='bash -c "
while true; do
    clear;
    echo \"=== PENDING / UNSCHEDULED WORKLOAD PODS ===\";
    RAW_PENDING=\$(kubectl get pods -A --field-selector=\"status.phase=Pending\" -o custom-columns=\"NAMESPACE:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,REASON:.status.conditions[?(@.type==\\\"PodScheduled\\\")].message\" 2>/dev/null | grep -v \"^kube-system \" || true);
    if [ \$(echo \"\$RAW_PENDING\" | wc -l) -le 1 ]; then
        echo \"No pending user workload pods (kube-system excluded).\";
    else
        echo \"\$RAW_PENDING\" | head -n 1;
        echo \"------------------------------------------------------------------------------------------------\";
        echo \"\$RAW_PENDING\" | tail -n +2;
    fi;
    sleep 15;
done
"'

# 1. Start tmux session with pane for NAP Info and capture its ID
PANE_NAP=$(tmux new-session -d -s "$SESSION_NAME" -n "NAP-Live-Dashboard" -P -F "#{pane_id}" "$CMD_NAP_INFO")

# 2. Split horizontally from PANE_NAP to create Nodes pane
PANE_NODES=$(tmux split-window -h -P -F "#{pane_id}" -t "$PANE_NAP" "$CMD_NODES")

# 3. Split vertically under PANE_NAP to create Default Pods pane
PANE_DEFAULT_PODS=$(tmux split-window -v -P -F "#{pane_id}" -t "$PANE_NAP" "$CMD_DEFAULT_PODS")

# 4. Split vertically under PANE_NODES to create Pending Pods pane
PANE_PENDING_PODS=$(tmux split-window -v -P -F "#{pane_id}" -t "$PANE_NODES" "$CMD_PENDING_PODS")

# Set layout and titles directly on each exact pane ID
tmux select-layout -t "$SESSION_NAME:0" tiled
tmux set-option -t "$SESSION_NAME" pane-border-status top
tmux set-option -t "$SESSION_NAME" pane-border-format " [ #{pane_title} ] "

tmux select-pane -t "$PANE_NAP" -T "1. Cluster & NAP Config"
tmux select-pane -t "$PANE_NODES" -T "2. Live Node Pools, Nodes & Taints"
tmux select-pane -t "$PANE_DEFAULT_PODS" -T "3. Pods in default Namespace"
tmux select-pane -t "$PANE_PENDING_PODS" -T "4. Pending Pods (Waiting on NAP)"

# Attach to the session
echo "Attaching to live tmux dashboard '$SESSION_NAME'..."
echo "To detach and leave running in background: press Ctrl+b, then d"
echo "To terminate the dashboard: run 'tmux kill-session -t $SESSION_NAME'"
tmux attach-session -t "$SESSION_NAME"
