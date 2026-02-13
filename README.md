# RHOAI Cluster Configuration - ArgoCD GitOps

This repository uses **OpenShift GitOps (ArgoCD)** to declaratively deploy and configure **Red Hat OpenShift AI (RHOAI)** and all of its operator dependencies on a blank OpenShift cluster.

Based on the [RHOAI Installation Workshop](https://github.com/redhat-ai-americas/rhoai-installation-workshop).

## What Gets Deployed

| Sync Wave | Resources | Description |
|-----------|-----------|-------------|
| 0 | Namespaces | All operator namespaces |
| 1 | OperatorGroups + Subscriptions | NFD, NVIDIA GPU, KMM, and all RHOAI dependency operators |
| 2 | RHOAI Operator | OperatorGroup + Subscription (waits for dependency operators) |
| 3 | NFD Instance, ClusterPolicy | GPU operator configuration |
| 4 | DataScienceCluster, Telemetry ConfigMap | RHOAI operator configuration |

### Operators Installed

- Node Feature Discovery (NFD)
- NVIDIA GPU Operator
- Kernel Module Management (KMM)
- Red Hat OpenShift AI (RHOAI)
- JobSet Operator
- Custom Metrics Autoscaler (KEDA)
- Leader Worker Set
- Red Hat Connectivity Link (Kuadrant)
- Kueue
- SR-IOV Network Operator
- Red Hat OpenTelemetry
- Tempo Operator
- Cluster Observability Operator

## Prerequisites

- OpenShift Container Platform 4.19+
- `oc` CLI installed and logged in as `cluster-admin`
- A GPU-capable node (or MachineSet) available in your cluster
- This repository pushed to a Git server reachable by the cluster

## Quick Start

1. **Clone and push to your Git server**

   ```bash
   git clone <this-repo>
   cd poc-template
   git remote set-url origin https://github.com/YOURORG/poc-template.git
   git push
   ```

2. **Update the ArgoCD Application repo URL**

   Edit `bootstrap/argocd-application.yaml` and replace the `repoURL` with your actual Git repository URL. Or the bootstrap script will prompt you.

3. **Run the bootstrap script**

   ```bash
   ./scripts/bootstrap.sh
   ```

4. **Monitor progress**

   ```bash
   # Get the ArgoCD URL
   oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'

   # Watch the Application status
   oc get application rhoai-cluster-config -n openshift-gitops -w
   ```

## Manual Steps After Sync

Some steps are cluster-specific and cannot be fully automated via GitOps:

1. **GPU MachineSet** - Create a GPU worker MachineSet for your cloud provider. See [RHOAI Installation Workshop Step 2](https://github.com/redhat-ai-americas/rhoai-installation-workshop/blob/main/docs/02-enable-gpu-support.md).

2. **Hardware Profile** - Create a Hardware Profile in the RHOAI dashboard to enable GPU assignment to workloads:
   - RHOAI Dashboard -> Settings -> Hardware profiles -> Create hardware profile
   - Add resource: `nvidia.com/gpu`, default `1`, min `1`, max `1`
   - Add toleration: operator `Exists`, effect `NoSchedule`, key `nvidia.com/gpu`
   - See [RHOAI 3.2 Hardware Profiles docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.2/html/working_with_accelerators/working-with-hardware-profiles_accelerators)

3. **GPU Node Taints** (optional) - Prevent non-GPU workloads from scheduling on GPU nodes. See [RHOAI Installation Workshop Step 5](https://github.com/redhat-ai-americas/rhoai-installation-workshop/blob/main/docs/05-configure-gpu-sharing-method.md).

## Sync Wave Architecture

```
Wave 0: Namespaces
  ↓ (namespaces exist)
Wave 1: Dependency Operator Subscriptions (NFD, GPU, KMM, Kueue, etc.)
  ↓ (ArgoCD waits for CSVs to succeed → CRDs registered)
Wave 2: RHOAI Operator Subscription
  ↓ (ArgoCD waits for RHOAI CSV to succeed → RHOAI CRDs registered)
Wave 3: GPU Configuration (NFD instance, ClusterPolicy)
  ↓ (GPU operator configures nodes)
Wave 4: RHOAI Configuration (DataScienceCluster, telemetry)
  ↓ (RHOAI components deploy)
```

ArgoCD's built-in health checks for OLM Subscriptions ensure that operators are fully installed (CSV in `Succeeded` phase) before proceeding to the next wave.

## Repository Structure

```
poc-template/
├── bootstrap/                          # One-time setup (not managed by ArgoCD)
│   ├── openshift-gitops-subscription.yaml
│   ├── argocd-cluster-admin.yaml
│   └── argocd-application.yaml
├── manifests/                          # Managed by ArgoCD
│   ├── operators/                      # Wave 0-2: Operator installations
│   │   ├── nfd.yaml
│   │   ├── nvidia-gpu.yaml
│   │   ├── kmm.yaml
│   │   ├── rhoai.yaml
│   │   ├── jobset.yaml
│   │   ├── custom-metrics-autoscaler.yaml
│   │   ├── leader-worker-set.yaml
│   │   ├── connectivity-link.yaml
│   │   ├── kueue.yaml
│   │   ├── sriov.yaml
│   │   ├── opentelemetry.yaml
│   │   ├── tempo.yaml
│   │   └── cluster-observability.yaml
│   ├── gpu-config/                     # Wave 3: GPU operator configuration
│   │   ├── nfd-instance.yaml
│   │   └── clusterpolicy.yaml
│   └── rhoai-config/                   # Wave 4: RHOAI configuration
│       ├── dsc.yaml
│       └── telemetry-cm.yaml
├── scripts/
│   └── bootstrap.sh
└── README.md
```
