#!/bin/bash
set -euo pipefail

# =============================================================================
# RHOAI Cluster Bootstrap Script
#
# This script installs OpenShift GitOps (ArgoCD) and configures it to manage
# the full RHOAI stack from the manifests in this repository.
#
# Prerequisites:
#   - oc CLI installed and logged in as cluster-admin
#   - Git repository pushed to a reachable URL
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/../bootstrap"

echo "============================================"
echo "  RHOAI Cluster Bootstrap"
echo "============================================"
echo ""

# -------------------------------------------------------------------
# Preflight checks
# -------------------------------------------------------------------
echo "[1/6] Preflight checks..."

if ! command -v oc &> /dev/null; then
  echo "ERROR: oc CLI not found. Install it first."
  exit 1
fi

if ! oc whoami &> /dev/null; then
  echo "ERROR: Not logged in to an OpenShift cluster. Run 'oc login' first."
  exit 1
fi

CURRENT_USER=$(oc whoami)
echo "  Logged in as: ${CURRENT_USER}"

# Check cluster-admin
if ! oc auth can-i '*' '*' --all-namespaces &> /dev/null; then
  echo "ERROR: Current user does not have cluster-admin privileges."
  exit 1
fi
echo "  Cluster-admin: confirmed"
echo ""

# -------------------------------------------------------------------
# Install OpenShift GitOps Operator
# -------------------------------------------------------------------
echo "[2/6] Installing OpenShift GitOps Operator..."

oc apply -f "${BOOTSTRAP_DIR}/openshift-gitops-subscription.yaml"
echo "  Subscription created. Waiting for operator to install..."
echo ""

# -------------------------------------------------------------------
# Wait for GitOps operator to be ready
# -------------------------------------------------------------------
echo "[3/6] Waiting for OpenShift GitOps operator CSV to succeed..."

RETRIES=60
DELAY=10
for i in $(seq 1 $RETRIES); do
  CSV=$(oc get csv -n openshift-gitops-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift GitOps")].status.phase}' 2>/dev/null || true)
  if [ "$CSV" = "Succeeded" ]; then
    echo "  GitOps operator is ready."
    break
  fi
  if [ "$i" -eq "$RETRIES" ]; then
    echo "ERROR: Timed out waiting for GitOps operator. Current status: ${CSV:-unknown}"
    exit 1
  fi
  echo "  Attempt ${i}/${RETRIES} - Status: ${CSV:-pending}. Retrying in ${DELAY}s..."
  sleep $DELAY
done
echo ""

# -------------------------------------------------------------------
# Wait for ArgoCD instance to be ready
# -------------------------------------------------------------------
echo "[4/6] Waiting for ArgoCD server to be ready..."

RETRIES=60
DELAY=10
for i in $(seq 1 $RETRIES); do
  READY=$(oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY:-0}" -ge 1 ]; then
    echo "  ArgoCD server is ready."
    break
  fi
  if [ "$i" -eq "$RETRIES" ]; then
    echo "ERROR: Timed out waiting for ArgoCD server."
    exit 1
  fi
  echo "  Attempt ${i}/${RETRIES} - Ready replicas: ${READY:-0}. Retrying in ${DELAY}s..."
  sleep $DELAY
done
echo ""

# -------------------------------------------------------------------
# Grant ArgoCD cluster-admin
# -------------------------------------------------------------------
echo "[5/6] Granting ArgoCD cluster-admin access..."

oc apply -f "${BOOTSTRAP_DIR}/argocd-cluster-admin.yaml"
echo "  ClusterRoleBinding created."
echo ""

# -------------------------------------------------------------------
# Create the ArgoCD Application
# -------------------------------------------------------------------
echo "[6/6] Creating ArgoCD Application..."

# Check if the user has updated the repo URL
if grep -q "YOURORG" "${BOOTSTRAP_DIR}/argocd-application.yaml"; then
  echo ""
  echo "WARNING: You need to update the repoURL in bootstrap/argocd-application.yaml"
  echo "         Replace 'https://github.com/YOURORG/poc-template.git' with your actual repo URL."
  echo ""
  read -p "Enter your Git repository URL: " REPO_URL
  if [ -z "$REPO_URL" ]; then
    echo "ERROR: No URL provided. Update bootstrap/argocd-application.yaml manually and run:"
    echo "  oc apply -f bootstrap/argocd-application.yaml"
    exit 1
  fi
  sed "s|https://github.com/YOURORG/poc-template.git|${REPO_URL}|" "${BOOTSTRAP_DIR}/argocd-application.yaml" | oc apply -f -
else
  oc apply -f "${BOOTSTRAP_DIR}/argocd-application.yaml"
fi

echo ""
echo "============================================"
echo "  Bootstrap Complete"
echo "============================================"
echo ""
echo "ArgoCD will now sync the manifests in the following order:"
echo "  Wave 0: Namespaces"
echo "  Wave 1: Dependency operator subscriptions (NFD, GPU, KMM, Kueue, etc.)"
echo "  Wave 2: RHOAI operator subscription"
echo "  Wave 3: GPU configuration (NFD instance, ClusterPolicy)"
echo "  Wave 4: RHOAI configuration (DataScienceCluster, telemetry)"
echo ""
echo "Monitor progress:"
echo "  ArgoCD UI:  oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'"
echo "  ArgoCD CLI: argocd app get rhoai-cluster-config"
echo "  oc:         oc get application rhoai-cluster-config -n openshift-gitops"
echo ""
echo "Manual steps still required after sync completes:"
echo "  1. Create a GPU MachineSet (cluster-specific, see hobbyist guide step 2)"
echo "  2. Create a Hardware Profile in the RHOAI dashboard (Settings -> Hardware profiles)"
echo "  3. Optionally configure GPU node taints (see hobbyist guide step 5)"
echo ""
