# GKE Spot VM Preemption & Graceful Workload Migration Demo

This module demonstrates how to run workloads resiliently on **Google Cloud Spot VMs** in Google Kubernetes Engine (GKE), handling preemption events with **zero downtime** and graceful connection draining.

---

## 💡 Overview: Spot VM Preemption Mechanics on GKE

Spot VMs offer a 60%–91% discount off standard Compute Engine pricing in exchange for Google being able to reclaim (preempt) capacity with short notice.

When Compute Engine preempts a Spot VM:
1. **25-Second Notice:** Compute Engine signals the upcoming shutdown through instance metadata (`http://metadata.google.internal/computeMetadata/v1/instance/preempted`).
2. **GKE Node Termination Notice:** The GKE node agent detects this signal and:
   - Taints the node with `cloud.google.com/gke-preempted="true":NoSchedule`.
   - Cordons the node so no new pods can be placed on it.
   - Issues a graceful eviction to all pods on that node.
3. **Application Grace Period:** 
   - Kubernetes sends a `SIGTERM` and triggers the container's `preStop` lifecycle hook.
   - The application has up to 25 seconds (we configure `terminationGracePeriodSeconds: 20`) to finish in-flight requests, close connections, and deregister from service endpoints.
4. **Traffic Continuity:**
   - Pod Disruption Budgets (`PDB`) ensure at least 1 replica is always available.
   - `topologySpreadConstraints` ensure replicas never all run on the same Spot VM.
   - Replacement pods are automatically scheduled on surviving or auto-scaled Spot VMs.

---

## 💰 Cost Optimization Profile
- **Cluster:** Single zone (`us-central1-c`), avoiding multi-zone cluster fee.
- **Node Pool:** 2 × `e2-medium` Spot VMs (~$0.015/hr each).
- **Total Burn Rate:** Under **$0.035 / hour** (~3.5 cents per hour).
- **Estimated Demo Run Cost:** **< $0.03 total**.

---

## 📂 Repository Structure

```
spot-resilience/
├── README.md                           # This guide
├── infra/
│   ├── spot-cluster-config.yaml        # Declarative GKE Spot cluster spec (gcloud --flags-file)
│   └── kube-dns-config.yaml            # Single-replica DNS config
├── k8s/                                # Raw Kubernetes YAML manifests
│   ├── 01-resilient-web-service.yaml   # Service & Deployment with preStop hook, spread constraints
│   ├── 02-pdb.yaml                     # PodDisruptionBudget (minAvailable: 1)
│   └── 03-traffic-generator.yaml       # Continuous HTTP probe (validates zero 5xx errors)
├── charts/
│   └── spot-preemption-demo/           # Packaged Helm chart with configurable values.yaml
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── pdb.yaml
│           └── traffic-probe.yaml
└── scripts/
    ├── 01-create-spot-cluster.sh       # Provisions 2-node Spot GKE cluster
    ├── 02-deploy-workloads.sh          # Installs the Helm chart
    ├── 03-simulate-preemption.sh       # Simulates GCP Spot VM preemption & tests traffic
    └── 04-cleanup.sh                   # Destroys workloads and cluster
```

---

## 🚀 Automated Execution (Quick Start)

### Step 1: Provision Cluster
```bash
./spot-resilience/scripts/01-create-spot-cluster.sh
```

### Step 2: Deploy Workloads
```bash
./spot-resilience/scripts/02-deploy-workloads.sh
```

### Step 3: Simulate Preemption & Verify Zero Downtime
```bash
./spot-resilience/scripts/03-simulate-preemption.sh
```

### Step 4: Tear Down
```bash
./spot-resilience/scripts/04-cleanup.sh
```

---

## 🛠️ Step-by-Step Manual Execution Guide

If you prefer running every command by hand from your terminal:

### 1. Provision Cluster from Declarative YAML
```bash
# Ensure project is set
gcloud config set project gke-naps

# Create 2-node Spot cluster
gcloud container clusters create spot-demo-cluster \
    --flags-file=spot-resilience/infra/spot-cluster-config.yaml

# Download kubeconfig
gcloud container clusters get-credentials spot-demo-cluster \
    --zone=us-central1-c \
    --project=gke-naps

# Apply single-replica DNS config
kubectl apply -f spot-resilience/infra/kube-dns-config.yaml
kubectl scale deployment kube-dns -n kube-system --replicas=1

# Verify nodes are running as Spot VMs
kubectl get nodes -o wide --show-labels | grep "cloud.google.com/gke-spot"
```

---

### 2. Deploy Resilient Workload via Helm
```bash
helm upgrade --install spot-demo ./spot-resilience/charts/spot-preemption-demo \
    --wait --timeout=120s

# Verify pod spread across nodes:
kubectl get pods -o wide -l app.kubernetes.io/component=resilient-web
```
*(Notice that each of the 2 replicas is scheduled on a different Spot VM node).*

---

### 3. Verify Continuous Traffic Probe
Check the continuous probe pod logs to confirm traffic is flowing:
```bash
kubectl logs -l app.kubernetes.io/component=traffic-probe --tail=10 -f
```
*(You will see recurring `Success (200 OK)` responses with 0 failures).*

---

### 4. Trigger GCP Simulated Preemption Event
Select one of the Spot VM nodes hosting a web replica and simulate a Google Cloud maintenance / preemption event:

```bash
# Find node hosting pod 1
TARGET_NODE=$(kubectl get pod -l app.kubernetes.io/component=resilient-web -o jsonpath='{.items[0].spec.nodeName}')
echo "Simulating preemption on: $TARGET_NODE"

# Trigger Compute Engine preemption signal:
gcloud compute instances simulate-maintenance-event "$TARGET_NODE" \
    --zone=us-central1-c \
    --project=gke-naps
```

---

### 5. Observe Graceful Eviction in Real Time
Run in parallel to watch the node and pod lifecycle:

```bash
# Watch node state transition (cordoned / preemption taint):
kubectl describe node "$TARGET_NODE" | grep -E "Taints:|Unschedulable"

# Watch the pod terminate gracefully and replacement pod start:
kubectl get pods -o wide -w

# Check traffic probe logs to verify zero dropped requests during the event:
kubectl logs -l app.kubernetes.io/component=traffic-probe --tail=20
```

---

### 6. Teardown & Cost Protection
```bash
# Uninstall Helm release
helm uninstall spot-demo

# Delete the cluster
gcloud container clusters delete spot-demo-cluster \
    --zone=us-central1-c \
    --project=gke-naps \
    --quiet
```

---

## 🔬 Advanced Architectural Scenarios & Deep Dive

### 1. What Happens When Existing Spot Pool Ceilings are Exhausted?
Suppose your application experiences a massive traffic spike:
* Your existing Spot node pool reaches its maximum node ceiling (e.g., `--max-nodes=4`), and all VMs are 100% full.
* New traffic demands 20 additional pods. Because the existing node pool cannot scale higher, incoming pods become `Pending` / `Unschedulable`.
* **If NAP is Enabled:**
  * Node Auto-Provisioning monitors unschedulable pods.
  * NAP ignores the individual node pool ceiling and instead evaluates your **cluster-wide limits** (`--max-cpu` and `--max-memory`).
  * If cluster limits have room, **NAP automatically provisions a brand-new, dynamic Spot node pool** on the fly (e.g., `nap-e2-standard-4-xxxx`), sized to host the spike.
  * When traffic subsides, NAP scales down and **destroys the dynamic pool completely**.

---

### 2. Can NAP Manage the Preemption Duration and Guarantee Zero Downtime?
**No—NAP alone without pre-existing headroom cannot beat the 25-second clock.**

* **The Reality:** 
  * Google Cloud gives exactly **25 seconds** notice before hard ACPI VM shutdown.
  * Provisioning a new VM, booting the OS, registering with the Kubernetes API, and pulling container images takes **90 to 120 seconds**.
* **The Gap:** 
  If you only have 1 Spot node and it gets preempted, there is an unavoidable **~65–95 second outage window** while NAP provisions the replacement node pool.
* **The Production Solution:**
  * **Topology Spread Constraints:** Run at least 2 replicas across distinct Spot nodes. When Node A is preempted, Node B continues serving 100% of the traffic while NAP boots the replacement node in the background.
  * **Hybrid Architecture:** Host 1 core replica on a small On-Demand VM, and burst scale using auto-provisioned Spot nodes.

---

### 3. What if Google Cloud Has No Spot Capacity Available for the Autoscaler?
During regional cloud shortages, Compute Engine may temporarily run out of Spot capacity for a specific machine family (e.g., `e2`):

* **Standard Cluster Autoscaler:** 
  * Tries to add more nodes of the **same pre-configured machine type**.
  * If GCP has no capacity for that exact type, scale-up fails and pods stay stuck in `Pending`.
* **Node Auto-Provisioning (NAP) Advantage:** 
  * NAP is machine-type agnostic.
  * If `e2` Spot VMs are unavailable, NAP can automatically evaluate alternative machine families (e.g., `n2d`, `c2`, `t2a`) that satisfy the pod's CPU/memory requirements and are currently available in GCP's Spot market.

---

### 4. Critical Sizing Consideration: Why You Must Plan Pod `maxReplicas` with HPA

A common production pitfall is assuming that enabling NAP automatically allows your application to handle unlimited traffic surges. 

**NAP does not monitor HTTP traffic directly; NAP only provisions nodes in response to pending Pods.**

Kubernetes scales via a two-tier hierarchy:
1. **Pod Layer (Horizontal Pod Autoscaler - HPA):** Monitors application metrics (CPU, memory, custom requests/sec) and scales **Pods** from `minReplicas` to `maxReplicas`.
2. **Node Layer (NAP / Cluster Autoscaler):** Monitors pod scheduling queues. When pods cannot fit on existing VMs, it provisions **Nodes**.

#### The Bottleneck Trap:
* If your Deployment has a fixed `replicas: 2`, or your HPA has `maxReplicas: 2`, Kubernetes will **refuse to create a 3rd pod** during a massive traffic surge.
* Because no new pods are created, there are zero `Pending` pods in the cluster queue.
* **NAP sees zero unschedulable pods and does nothing.**
* Your 2 existing pods become saturated, CPU throttled, and incoming traffic times out with HTTP 503 / 504 errors, despite NAP having ample cluster CPU headroom!

#### The Three Limits to Align in Production:
To ensure end-to-end elasticity during traffic spikes on Spot VMs:

| Scaling Tier | Configuration Resource | Key Parameter | Purpose |
| :--- | :--- | :--- | :--- |
| **Tier 1: Application** | `HorizontalPodAutoscaler` | `maxReplicas: 50` | Allows Kubernetes to generate enough pods to absorb the incoming traffic spike. |
| **Tier 2: Node Pool (Optional)** | `gcloud ... node-pools` | `max-nodes: 4` | Caps the primary static Spot node pool. |
| **Tier 3: Dynamic Cluster (NAP)** | `gcloud ... --max-cpu` | `--max-cpu=64`<br>`--max-memory=256` | Sets the global safety boundary for NAP to create dynamic Spot node pools when Tier 2 is full. |

#### Example Production HPA Manifest:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: resilient-web-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: resilient-web
  minReplicas: 2      # Always maintain at least 2 for Spot preemption survival
  maxReplicas: 30     # Sufficient ceiling to handle peak traffic bursts
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
```

---

## ⚙️ Complete Reference: All Configurable NAP Parameters

Node Auto-Provisioning is controlled via two distinct configuration layers:

### 1. Cluster-Level Configuration (`gcloud` / Terraform)
These flags define the global safety boundaries, limits, and defaults for all dynamically provisioned pools:

| Parameter Flag | Example Value | Description |
| :--- | :--- | :--- |
| `--enable-autoprovisioning` | `true` | Enables Node Auto-Provisioning on the cluster. |
| `--min-cpu` / `--max-cpu` | `--min-cpu=1 --max-cpu=32` | Hard floor and ceiling on total vCPUs across all nodes in the cluster (prevents runaway billing). |
| `--min-memory` / `--max-memory` | `--min-memory=2 --max-memory=128` | Hard floor and ceiling on total RAM (in GB) across all cluster nodes. |
| `--min-accelerator` / `--max-accelerator` | `type=nvidia-tesla-t4,count=2` | Sets bounds on specialized hardware accelerators (GPUs/TPUs). |
| `--autoprovisioning-scopes` | `https://www.googleapis.com/auth/cloud-platform` | Default OAuth API access scopes assigned to VMs in dynamically created node pools. |
| `--autoprovisioning-service-account` | `sa-name@project.iam.gserviceaccount.com` | Custom GCP IAM Service Account attached to auto-provisioned VMs. |
| `--autoprovisioning-locations` | `us-central1-a,us-central1-c` | Restricts which compute zones NAP is permitted to spawn new node pools in. |
| `--autoprovisioning-disk-type` | `pd-standard` / `pd-balanced` / `pd-ssd` | Default boot disk type for auto-provisioned nodes. |
| `--autoprovisioning-disk-size` | `100` | Boot disk size in GB for auto-provisioned nodes. |
| `--autoprovisioning-image-type` | `COS_CONTAINERD` / `UBUNTU_CONTAINERD` | Base OS image for auto-provisioned nodes. |
| `--autoscaling-profile` | `balanced` or `optimize-utilization` | `optimize-utilization` prioritizes bin-packing pods and scales down unneeded nodes aggressively. |

---

### 2. Pod-Level Configuration (Kubernetes YAML Manifests)
Developers steer what type of node pool NAP creates by specifying labels and tolerations inside the Pod specification:

* **Request Spot VM Node Pool:**
  ```yaml
  nodeSelector:
    cloud.google.com/gke-spot: "true"
  tolerations:
  - key: "cloud.google.com/gke-spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
  ```

* **Specify Machine Family / Architecture:**
  ```yaml
  nodeSelector:
    cloud.google.com/machine-family: "n2d"  # Or c2, e2, etc.
    kubernetes.io/arch: "arm64"             # Provisions ARM-based Tau T2A nodes
  ```

* **Request Dedicated Tainted Node Pool (Tenant Isolation):**
  ```yaml
  nodeSelector:
    workload-tier: "secure-pci"
  tolerations:
  - key: "workload-tier"
    operator: "Equal"
    value: "secure-pci"
    effect: "NoSchedule"
  ```
  *(NAP automatically provisions a dedicated node pool stamped with this exact taint and label).*
