# GKE Node Auto-Provisioning (NAP) - Declarative YAML & Helm Demo

This repository provides an Infrastructure-as-Code (IaC) and Helm-driven demonstration of **GKE Node Auto-Provisioning (NAP)** in Google Cloud.

Node Auto-Provisioning (NAP) dynamically manages Kubernetes node pools. Rather than merely scaling an existing node pool up and down, NAP **dynamically creates new node pools** with optimal machine shapes, taints, tolerations, or Spot settings whenever unschedulable pods appear, and deletes those node pools when workloads finish.

---

## 💰 Cost Optimization Features
Designed specifically for personal Google Cloud accounts:
- **Zonal Cluster:** Single zone (`us-central1-c`), avoiding multi-zone cluster management overhead.
- **Spot VMs (`--spot`):** Saves 60%–91% compared to standard on-demand compute instances.
- **Minimal Initial Node Pool:** 1 single `e2-standard-2` node (2 vCPU, 8 GB RAM) for cluster system pods.
- **Hard Resource Limits:** Auto-provisioning CPU ceiling is capped at 8 vCPUs and 32 GB RAM.
- **Single DNS Replica Config:** Pinned via [`infra/kube-dns-config.yaml`](infra/kube-dns-config.yaml) to keep DNS on the baseline pool and ensure dynamic nodes scale down without blockers.

---

## 🔄 Node Lifecycle: Scale-Up & Scale-Down Behavior

Understanding how GKE handles the lifecycle of different node pools is crucial when workloads are deleted:

| Node Pool Type | Pool Name | Behavior on Workload Deletion | Reason |
| :--- | :--- | :--- | :--- |
| **Dynamically Auto-Provisioned** | `nap-e2-standard-4-...` | **Automatically scaled to 0 & deleted** after a cooldown period (~10–15 mins) | NAP manages the full lifecycle of dynamic pools. Once all user pods are uninstalled and the node is idle, NAP deletes the entire node pool. |
| **Initial / Baseline** | `default-pool` | **Remains running** (1 node) | Houses cluster system daemonsets (CoreDNS, kube-proxy, metrics-server, metadata agents). It remains active as long as the cluster exists. |

> [!NOTE]
> **Why the 10–15 Minute Cooldown Window?**  
> GKE Cluster Autoscaler / NAP intentionally does not delete dynamic nodes the exact second a pod is removed. It enforces a scale-down delay (cooldown) to avoid "thrashing" (rapidly spinning nodes down and back up if new pods arrive immediately after rolling updates or batch runs).

---

## 📂 Repository Structure

```
├── README.md
├── infra/
│   ├── cluster-config.yaml         # Declarative YAML infrastructure spec for GKE (gcloud --flags-file)
│   └── kube-dns-config.yaml        # Declarative ConfigMap pinning DNS to 1 replica to prevent NAP lock
├── charts/
│   └── gke-naps-demo/              # Helm chart packaging demo workloads
│       ├── Chart.yaml
│       ├── values.yaml             # Single source of truth for workloads & resource requests
│       └── templates/
│           ├── baseline-deployment.yaml
│           ├── cpu-workload-deployment.yaml
│           ├── tainted-workload-deployment.yaml
│           └── spot-workload-deployment.yaml
├── k8s/                            # Raw standalone YAML manifests (alternative to Helm)
│   ├── 01-baseline-app.yaml
│   ├── 02-nap-cpu-workload.yaml
│   ├── 03-nap-tainted-workload.yaml
│   └── 04-nap-spot-workload.yaml
└── scripts/
    ├── 01-create-cluster.sh        # Provisions GKE cluster using infra/cluster-config.yaml & infra/kube-dns-config.yaml
    ├── 02-run-demo.sh              # Runs the end-to-end Helm demo
    └── 03-cleanup.sh              # Uninstalls Helm chart & destroys cluster
```

---

## 📄 Declarative Infrastructure Specs in `infra/`

### 1. Cluster Specification: `infra/cluster-config.yaml`
Used with `gcloud container clusters create naps-demo-cluster --flags-file=infra/cluster-config.yaml`:

```yaml
--project: "gke-naps"
--zone: "us-central1-c"

# Baseline Node Pool (1 Spot VM of e2-standard-2)
--num-nodes: 1
--machine-type: "e2-standard-2"
--spot: true

# Node Auto-Provisioning (NAP) Settings
--enable-autoprovisioning: true

# Cluster-wide resource limits for auto-provisioned pools
--min-cpu: 1
--max-cpu: 8
--min-memory: 2
--max-memory: 32

--autoprovisioning-scopes:
  - "https://www.googleapis.com/auth/cloud-platform"
```

### 2. DNS Auto-Scale Specification: `infra/kube-dns-config.yaml`
Used with `kubectl apply -f infra/kube-dns-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns-autoscaler
  namespace: kube-system
data:
  linear: '{"coresPerReplica":256,"includeUnschedulableNodes":true,"nodesPerReplica":16,"preventSinglePointFailure":false,"min":1}'
```

---

## ⎈ Declarative Workloads via Helm Chart: `charts/gke-naps-demo/`

Workloads are configured in [`charts/gke-naps-demo/values.yaml`](charts/gke-naps-demo/values.yaml). You can toggle and document individual test scenarios:

| Scenario | Values Key | Pod Request | NAP Behavior |
| :--- | :--- | :--- | :--- |
| **Baseline** | `baselineWorkload.enabled` | 100m CPU, 128Mi RAM | Fits on initial node pool (`default-pool`). No scale-up. |
| **High CPU** | `cpuWorkload.enabled` | 3000m CPU, 4Gi RAM | Exceeds default node capacity. NAP creates a new `nap-*` node pool. |
| **Tainted Pool** | `taintedWorkload.enabled` | 500m CPU + Taint/Toleration | NAP creates a dedicated, tainted node pool for isolated workloads. |
| **Spot Pool** | `spotWorkload.enabled` | 500m CPU + Spot Selector | NAP provisions a dedicated Spot VM node pool. |

---

## 🚀 Execution Guide (Automated Scripts)

If you prefer quick execution via the provided bash scripts:

### Step 1: Provision the GKE Cluster
Execute the setup script (which runs `gcloud container clusters create --flags-file=infra/cluster-config.yaml` and applies `infra/kube-dns-config.yaml`):
```bash
./scripts/01-create-cluster.sh
```

### Step 2: Run the Demo
Execute the automated Helm demo script:
```bash
./scripts/02-run-demo.sh
```

### Step 3: Tear Down & Cost Protection
Uninstall the Helm release and destroy the cluster when finished:
```bash
./scripts/03-cleanup.sh
```

---

## 🛠️ Complete Step-by-Step Manual Execution Guide (From Local Machine)

If you prefer to run every command manually from your local terminal to inspect each step:

### 1. Local Authentication & Prerequisites Setup
All operations run from your local terminal using `gcloud`, `kubectl`, and `helm`.

```bash
# 1. Authenticate gcloud with your personal Google account
gcloud auth login

# 2. Set active GCP project
gcloud config set project gke-naps

# 3. Enable required Google Cloud APIs
gcloud services enable container.googleapis.com compute.googleapis.com

# 4. Install mandatory GKE auth plugin for kubectl on your local machine
gcloud components install gke-gcloud-auth-plugin --quiet

# 5. Verify the auth plugin binary is installed
which gke-gcloud-auth-plugin
```

---

### 2. Create the GKE Cluster Declaratively from Local CLI
Run `gcloud` locally using the declarative YAML configuration file:

```bash
# Provision cluster from YAML spec
gcloud container clusters create naps-demo-cluster \
    --flags-file=infra/cluster-config.yaml

# Download the cluster endpoint and CA certificate into local ~/.kube/config
gcloud container clusters get-credentials naps-demo-cluster \
    --zone=us-central1-c \
    --project=gke-naps

# Apply the declarative DNS config so kube-dns does not block dynamic node deletion
kubectl apply -f infra/kube-dns-config.yaml
kubectl scale deployment kube-dns -n kube-system --replicas=1

# Verify local kubectl can communicate with the cluster
kubectl get nodes -o wide

# Verify only the single baseline node pool exists
gcloud container node-pools list \
    --cluster=naps-demo-cluster \
    --zone=us-central1-c \
    --project=gke-naps
```

---

### 3. Deploy Baseline Workload
Deploy a small workload requiring 100m CPU to demonstrate that it runs on the initial `default-pool`:

```bash
# Using Helm:
helm upgrade --install naps-demo ./charts/gke-naps-demo \
    --set baselineWorkload.enabled=true \
    --set cpuWorkload.enabled=false \
    --set taintedWorkload.enabled=false \
    --set spotWorkload.enabled=false

# (Or using raw kubectl: kubectl apply -f k8s/01-baseline-app.yaml)

# Verify pod is Running on default-pool
kubectl get pods -o wide
```

---

### 4. Trigger Node Auto-Provisioning (High-CPU Workload)
Upgrade the Helm deployment to enable the high-CPU workload demanding 3 vCPUs (`3000m`). Since `default-pool` (`e2-standard-2`) only has ~1.8 vCPU allocatable, the pod cannot schedule there:

```bash
# Upgrade Helm release to enable the 3-vCPU workload
helm upgrade naps-demo ./charts/gke-naps-demo \
    --set baselineWorkload.enabled=true \
    --set cpuWorkload.enabled=true

# (Or using raw kubectl: kubectl apply -f k8s/02-nap-cpu-workload.yaml)

# Check pod status (it will show Status: Pending / Reason: Unschedulable)
kubectl get pods -l app.kubernetes.io/component=cpu-workload
```

---

### 5. Observe Dynamic Node Pool Creation in Real Time
Watch GKE Node Auto-Provisioner detect the unschedulable pod and dynamically create a new node pool:

```bash
# 1. Watch node pools list (in ~60-90s a new nap-e2-standard-4-... pool appears)
gcloud container node-pools list \
    --cluster=naps-demo-cluster \
    --zone=us-central1-c \
    --project=gke-naps

# 2. Watch new node boot up and join the cluster
kubectl get nodes -w

# 3. Confirm the workload pod transitions to Running on the new dynamic node
kubectl get pods -o wide
```

---

### 6. (Optional) Test Tainted / Spot Node Pools
Demonstrate NAP creating specialized isolated pools:

```bash
# Test custom taint & toleration node pool
helm upgrade naps-demo ./charts/gke-naps-demo \
    --set taintedWorkload.enabled=true

# Test dedicated Spot VM node pool
helm upgrade naps-demo ./charts/gke-naps-demo \
    --set spotWorkload.enabled=true
```

---

### 7. Teardown Workloads & Final Cluster Cleanup
Avoid ongoing charges on your personal Google Cloud account:

```bash
# 1. Uninstall the Helm demo workloads
helm uninstall naps-demo
# (With infra/kube-dns-config.yaml in place, NAP automatically deletes the dynamic nap-* node pool when idle)

# 2. Delete the GKE cluster to completely stop all billing
gcloud container clusters delete naps-demo-cluster \
    --zone=us-central1-c \
    --project=gke-naps \
    --quiet
```

---

## 🔍 Troubleshooting & Validation: Dynamic Node Deletion

When you uninstall workloads, why might the dynamic `nap-*` node pool remain in the cluster, and how do you diagnose and verify scale-down?

---

### ⚠️ Issue Scenario: Dynamic Node Not Destroyed after Workload Uninstall

#### 1. Why it happened (The "Before" Scenario)
When `helm uninstall naps-demo` was executed, the dynamic node pool (`nap-e2-standard-4-...`) did not delete after the cooldown. 

By default, GKE's `kube-dns-autoscaler` has `"preventSinglePointFailure": true`. As soon as NAP created the 2nd node, GKE scheduled a second replica of `kube-dns` on it with pod anti-affinity. In Kubernetes, **Cluster Autoscaler refuses to evict non-replicated system pods or pods that cannot safely reschedule**. Because `kube-dns` could not fit on `default-pool` (where replica 1 was already running), the autoscaler declared the node non-evictable.

#### 2. Diagnostic Commands to Validate the Blocker
To see what pods are preventing node scale down:

```bash
# Check all pods scheduled on the dynamic NAP node
kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=<NAP_NODE_NAME>

# Inspect the live Cluster Autoscaler status configmap
kubectl get configmap -n kube-system cluster-autoscaler-status -o yaml | grep -A 25 "scaleDown:"
```

**Diagnostic Output when blocked:**
```yaml
scaleDown:
  lastProbeTime: "2026-10-22T02:52:45Z"
  status: NoCandidates    # <-- Indicates Autoscaler cannot find any evictable nodes
```

Check `kube-dns` placement and anti-affinity:
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```
*(You would see one `kube-dns` pod on `default-pool` and the other on the `nap-*` node).*

---

### ✅ The Fix: Resolving the DNS Blocker & Draining

1. **Apply the single-replica DNS config:**
   ```bash
   kubectl apply -f infra/kube-dns-config.yaml
   kubectl scale deployment kube-dns -n kube-system --replicas=1
   ```

2. **Drain the node to evict any lingering system replicas:**
   ```bash
   kubectl drain <NAP_NODE_NAME> --delete-emptydir-data --ignore-daemonsets --force
   ```

---

### 📊 Validation Commands: Verifying Node is Cordoned and Planned for Deletion

Once the node is cordoned and empty, verify that GKE Autoscaler flags it for deletion:

#### 1. Check Node Scheduling Status
```bash
kubectl get nodes
```
**Expected Output:**
```
NAME                                                  STATUS                     ROLES    AGE   VERSION
gke-naps-demo-cluste-nap-e2-standard--20a46abb-z2q8   Ready,SchedulingDisabled   <none>   36m   v1.36.4-gke.1495002
gke-naps-demo-cluster-default-pool-e99ecc7d-0mx1      Ready                      <none>   52m   v1.36.4-gke.1495002
```
*`Ready,SchedulingDisabled` confirms the node is cordoned and no new pods can be placed on it.*

#### 2. Verify Candidate Status in Autoscaler
```bash
kubectl get configmap -n kube-system cluster-autoscaler-status -o yaml | grep -A 25 "scaleDown:"
```
**Expected Output:**
```yaml
scaleDown:
  candidates: 1           # <-- Autoscaler confirmed the node is an eviction candidate!
  lastTransitionTime: "2026-10-22T03:01:27Z"
  status: CandidatesPresent
```
*`CandidatesPresent` means the 10-minute scale-down cooldown timer has officially started.*

#### 3. Verify Permanent Deletion
After the ~10-minute cooldown window elapses, verify that the dynamic node and node pool are completely gone:

```bash
# Verify only the default node remains:
kubectl get nodes

# Verify only default-pool exists in GKE:
gcloud container node-pools list --cluster=naps-demo-cluster --zone=us-central1-c --project=gke-naps
```
**Expected Output:**
```
NAME          MACHINE_TYPE   DISK_SIZE_GB  NODE_VERSION
default-pool  e2-standard-2  100           1.36.4-gke.1495002
```
*(The `nap-e2-standard-4-...` node pool has been deleted by NAP).*
