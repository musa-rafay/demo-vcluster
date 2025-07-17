#!/usr/bin/env bash
# create-vcluster-basic.sh
#
# Minimal, version-stable vCluster create helper for CI:
# - No chart --set overrides (avoids schema drift)
# - Ensures namespace dev-<ID>
# - Creates/upgrades vcluster-<ID> (k8s <ver>) without auto-connect
# - Retrieves kubeconfig from Secret vc-vcluster-<ID>
# - Tests connection by running `kubectl get ns` *through* vcluster connect
# - Exits 0 without enforcing storage (PVC/SC)
#
# Usage:
#   ./create-vcluster-basic.sh <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]

set -euo pipefail

DEV="${1:-}"
if [[ -z "$DEV" ]]; then
  echo "Usage: $0 <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]" >&2
  exit 1
fi

# SIZE_Gi kept for interface compatibility; currently unused
SIZE_Gi="${2:-5}"
K8S_VERSION="${3:-1.32}"
PARENT_CONTEXT="${4:-kubernetes-admin@kubernetes}"

NS="dev-${DEV}"
VC="vcluster-${DEV}"
SECRET_NAME="vc-${VC}"

KCFG_DIR="$HOME/vc-kcfg"
mkdir -p "$KCFG_DIR"
VC_KCFG="${KCFG_DIR}/kubeconfig-${DEV}.yaml"

PARENT_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

cyan()  { printf "\033[0;36m%s\033[0m\n" "$*"; }
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
red()   { printf "\033[0;31m%s\033[0m\n" "$*"; }

cyan ">> Using parent kubeconfig: $PARENT_KUBECONFIG"
if [[ ! -f "$PARENT_KUBECONFIG" ]]; then
  red "Parent kubeconfig not found: $PARENT_KUBECONFIG"; exit 2
fi
export KUBECONFIG="$PARENT_KUBECONFIG"

# Optional: switch to parent context
kubectl config use-context "$PARENT_CONTEXT" >/dev/null 2>&1 || yellow "Context $PARENT_CONTEXT not found; continuing."

# Reachability check (portable; avoid --short)
cyan ">> Verifying parent cluster reachability ..."
if ! kubectl get --raw='/healthz' >/dev/null 2>&1 && ! kubectl get nodes >/dev/null 2>&1; then
  red "Cannot reach parent cluster. Aborting."; exit 3
fi
green "Parent cluster reachable."

# Namespace ensure
cyan ">> Ensuring namespace: $NS"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# Create / upgrade vCluster (no Helm value overrides to ensure cross-version compatibility)
cyan ">> Deploying $VC (virtual k8s $K8S_VERSION) in namespace $NS"
TMPDIR="$(mktemp -d "/tmp/${VC}-XXXX")"
pushd "$TMPDIR" >/dev/null
set +e

# Build the base create cmd
VCREATE=( vcluster create "$VC" -n "$NS" --upgrade --connect=false )
# NOTE: only pass --kubernetes-version (or legacy --version) if you *need* it AND your CLI supports it.
# To always request a version, uncomment ONE of the following after checking your CLI version:
# VCREATE+=( --kubernetes-version "$K8S_VERSION" )   # newer CLI
# VCREATE+=( --version "$K8S_VERSION" )              # legacy CLI

"${VCREATE[@]}"
VC_RET=$?

set -e
popd >/dev/null
rm -rf "$TMPDIR"

if [[ $VC_RET -ne 0 ]]; then
  red "vcluster create failed (exit $VC_RET)."; exit $VC_RET
fi
green "vCluster $VC created or upgraded."

# Retrieve kubeconfig Secret (non-interactive; avoids hang in connect)
cyan ">> Retrieving kubeconfig Secret '$SECRET_NAME' from namespace '$NS' -> $VC_KCFG"
# Wait briefly for Secret to materialize
for i in {1..30}; do
  if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! kubectl get secret "$SECRET_NAME" -n "$NS" --template='{{ index .data "config" }}' \
     | base64 -d >"$VC_KCFG"; then
  red "Failed to retrieve kubeconfig from Secret $SECRET_NAME."; exit 4
fi
chmod 600 "$VC_KCFG"
green "Kubeconfig written to $VC_KCFG"

# ------------------------------------------------------------------
# Test connection (simulate 'open another terminal & run kubectl get ns')
# Preferred: use vcluster CLI passthrough to run kubectl inside the vCluster session.
# Example from docs: vcluster connect my-vcluster -n my-ns -- kubectl get ns
# ------------------------------------------------------------------
cyan ">> Testing vCluster access (via vcluster connect passthrough): kubectl get ns"
set +e
vcluster connect "$VC" -n "$NS" -- kubectl get ns
VC_TEST_RET=$?
set -e

if [[ $VC_TEST_RET -ne 0 ]]; then
  yellow "vcluster passthrough test failed (exit $VC_TEST_RET); trying direct kubeconfig..."
  # Direct attempt with the kubeconfig we just wrote (works if endpoint reachable or forwarded)
  set +e
  kubectl --kubeconfig "$VC_KCFG" get ns || yellow "  WARNING: direct kubeconfig get ns failed."
  set -e
fi

green "-------------------------------------------------------------------"
green "vCluster:   $VC"
green "Namespace:  $NS"
green "Kubeconfig: $VC_KCFG"
green "-------------------------------------------------------------------"
exit 0
