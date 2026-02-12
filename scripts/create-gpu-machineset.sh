#!/bin/bash
set -euo pipefail

# =============================================================================
# Create a GPU MachineSet on AWS OpenShift
#
# Clones an existing worker MachineSet and modifies it for GPU instances.
#
# Usage:
#   ./scripts/create-gpu-machineset.sh <instance-type> [replicas]
#
# Examples:
#   ./scripts/create-gpu-machineset.sh g6e.4xlarge       # L40S, 1 GPU
#   ./scripts/create-gpu-machineset.sh g4dn.4xlarge      # T4, 1 GPU
#   ./scripts/create-gpu-machineset.sh p4d.24xlarge       # A100, 8 GPUs
#   ./scripts/create-gpu-machineset.sh g6e.4xlarge 2      # 2 replicas
# =============================================================================

INSTANCE_TYPE=${1:-}
REPLICAS=${2:-1}

if [ -z "$INSTANCE_TYPE" ]; then
  echo "Usage: $0 <instance-type> [replicas]"
  echo ""
  echo "Common GPU instance types:"
  echo "  g6e.4xlarge    - NVIDIA L40S (48GB), 1 GPU"
  echo "  g6e.12xlarge   - NVIDIA L40S (48GB), 4 GPUs"
  echo "  g4dn.4xlarge   - NVIDIA T4 (16GB), 1 GPU"
  echo "  g4dn.12xlarge  - NVIDIA T4 (16GB), 4 GPUs"
  echo "  g5.4xlarge     - NVIDIA A10G (24GB), 1 GPU"
  echo "  p4d.24xlarge   - NVIDIA A100 (40GB), 8 GPUs"
  echo "  p5.48xlarge    - NVIDIA H100 (80GB), 8 GPUs"
  exit 1
fi

GPU_MS_NAME="cluster-${INSTANCE_TYPE/./-}-gpu"

echo "============================================"
echo "  Create GPU MachineSet"
echo "============================================"
echo ""
echo "  Instance type: ${INSTANCE_TYPE}"
echo "  MachineSet:    ${GPU_MS_NAME}"
echo "  Replicas:      ${REPLICAS}"
echo ""

# -------------------------------------------------------------------
# Preflight
# -------------------------------------------------------------------
if ! oc whoami &> /dev/null; then
  echo "ERROR: Not logged in to an OpenShift cluster."
  exit 1
fi

# Check if GPU machineset already exists
EXISTING=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name 2>/dev/null | grep "${INSTANCE_TYPE%.*}" | head -n1 || true)
if [ -n "$EXISTING" ]; then
  echo "GPU MachineSet already exists: ${EXISTING}"
  echo "Current replicas: $(oc -n openshift-machine-api get "${EXISTING}" -o jsonpath='{.spec.replicas}')"
  echo ""
  read -p "Scale to ${REPLICAS} replicas? (y/n): " CONFIRM
  if [ "$CONFIRM" = "y" ]; then
    oc -n openshift-machine-api scale "${EXISTING}" --replicas="${REPLICAS}"
    echo "Scaled to ${REPLICAS} replicas."
  fi
  exit 0
fi

# -------------------------------------------------------------------
# Find a worker MachineSet to clone
# -------------------------------------------------------------------
echo "[1/4] Finding worker MachineSet to clone..."

WORKER_MS=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep worker | head -n1)

if [ -z "$WORKER_MS" ]; then
  echo "ERROR: No worker MachineSet found to clone."
  exit 1
fi

echo "  Cloning from: ${WORKER_MS}"
echo ""

# -------------------------------------------------------------------
# Clone and modify the MachineSet
# -------------------------------------------------------------------
echo "[2/4] Creating GPU MachineSet..."

oc -n openshift-machine-api get "${WORKER_MS}" -o yaml | \
  sed '/machine/ s/'"${WORKER_MS##*/}"'/'"${GPU_MS_NAME}"'/g
    /^  name:/ s/'"${WORKER_MS##*/}"'/'"${GPU_MS_NAME}"'/g
    /name/ s/'"${WORKER_MS##*/}"'/'"${GPU_MS_NAME}"'/g
    s/instanceType.*/instanceType: '"${INSTANCE_TYPE}"'/
    /cluster-api-autoscaler/d
    /uid:/d
    /generation:/d
    /resourceVersion:/d
    /creationTimestamp:/d
    s/replicas.*/replicas: 0/' | \
  oc apply -f -

echo ""

# -------------------------------------------------------------------
# Patch with GPU labels and metadata
# -------------------------------------------------------------------
echo "[3/4] Patching GPU labels..."

MACHINE_SET_TYPE=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep "${INSTANCE_TYPE%.*}" | head -n1)

# GPU node role label
oc -n openshift-machine-api \
  patch "${MACHINE_SET_TYPE}" \
  --type=merge --patch '{"spec":{"template":{"spec":{"metadata":{"labels":{"node-role.kubernetes.io/gpu":""}}}}}}'

# Accelerator label for autoscaler
oc -n openshift-machine-api \
  patch "${MACHINE_SET_TYPE}" \
  --type=merge --patch '{"spec":{"template":{"spec":{"metadata":{"labels":{"cluster-api/accelerator":"nvidia-gpu"}}}}}}'

oc -n openshift-machine-api \
  patch "${MACHINE_SET_TYPE}" \
  --type=merge --patch '{"metadata":{"labels":{"cluster-api/accelerator":"nvidia-gpu"}}}'

# Ensure instance type is set
oc -n openshift-machine-api \
  patch "${MACHINE_SET_TYPE}" \
  --type=merge --patch '{"spec":{"template":{"spec":{"providerSpec":{"value":{"instanceType":"'"${INSTANCE_TYPE}"'"}}}}}}'

echo ""

# -------------------------------------------------------------------
# Scale up
# -------------------------------------------------------------------
echo "[4/4] Scaling to ${REPLICAS} replica(s)..."

oc -n openshift-machine-api scale "${MACHINE_SET_TYPE}" --replicas="${REPLICAS}"

echo ""
echo "============================================"
echo "  GPU MachineSet Created"
echo "============================================"
echo ""
echo "  MachineSet: ${GPU_MS_NAME}"
echo "  Instance:   ${INSTANCE_TYPE}"
echo "  Replicas:   ${REPLICAS}"
echo ""
echo "Monitor provisioning:"
echo "  oc -n openshift-machine-api get machines -w"
echo ""
echo "Once the node is Ready, the GPU Operator will automatically"
echo "install drivers and configure the GPU."
echo ""
