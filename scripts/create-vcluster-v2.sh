#!/usr/bin/env bash
# create-vcluster-min.sh
#
# Minimal, version-agnostic vCluster create script:
# - NO chart --set lines (avoids schema drift)
# - Creates namespace dev-<ID>
# - Creates / upgrades vcluster-<ID> (k8s <ver>)
# - Writes kubeconfig to ~/vc-kcfg/kubeconfig-<ID>.yaml
# - Ensures >=N Gi PVC "vc-shared" inside vCluster (fallback SC if needed)
#
# Usage:
#   ./create-vcluster-min.sh <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]

set -euo pipefail

DEV="${1:-}"
if [[ -z "$DEV" ]]; then
  echo "Usage: $0 <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]" >&2
  exit 1
fi
SIZE_Gi="${2:-5}"
K8S_VERSION="${3:-1.32}"
PARENT_CONTEXT="${4:-kubernetes-admin@kubernetes}"

NS="dev-${DEV}"
VC="vcluster-${DEV}"

# locations
KCFG_DIR="$HOME/vc-kcfg"
mkdir -p "$KCFG_DIR"
FALLBACK_HOSTPATH_BASE="/tmp/vc-storage"
mkdir -p "$FALLBACK_HOSTPATH_BASE" || true

# Flannel (optional; best-effort)
FLANNEL_MANIFEST_URL="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

# parent kubeconfig (honor incoming env override)
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

# ensure we're pointed at parent cluster (best effort)
kubectl config use-context "$PARENT_CONTEXT" >/dev/null 2>&1 || yellow "Context $PARENT_CONTEXT not found; continuing with current."

# reachability (portable; avoid --short)
cyan ">> Verifying parent cluster reachability ..."
if ! kubectl get --raw='/healthz' >/dev/null 2>&1 && ! kubectl get nodes >/dev/null 2>&1; then
  red "Cannot reach parent cluster. Aborting."; exit 3
fi
green "Parent cluster reachable."

# kernel sysctls (best effort; ignore failures)
cyan ">> Ensuring host kernel params for networking ..."
{
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1    >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv4.ip_forward=1                   >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv6.conf.all.forwarding=1          >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv4.conf.all.promote_secondaries=1 >/dev/null 2>&1 || true
} || true

# Flannel (best effort)
cyan ">> Checking Flannel CNI ..."
if ! kubectl -n kube-flannel get ds kube-flannel-ds >/dev/null 2>&1; then
  echo "  Installing Flannel (best-effort)."
  kubectl apply --validate=false -f "$FLANNEL_MANIFEST_URL" >/dev/null 2>&1 || yellow "  WARNING: Flannel install failed; continuing."
else
  echo "  Flannel already present; skipping."
fi
echo "  Waiting up to 180s for Flannel rollout ..."
kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=180s >/dev/null 2>&1 || yellow "  WARNING: Flannel rollout not confirmed; continuing."

# namespace
cyan ">> Ensuring namespace: $NS"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# create / upgrade vCluster (NO --set lines)
cyan ">> Deploying $VC (virtual k8s $K8S_VERSION) in namespace $NS"
TMPDIR="$(mktemp -d "/tmp/${VC}-XXXX")"
pushd "$TMPDIR" >/dev/null
set +e
vcluster create "$VC" \
  -n "$NS" \
  --upgrade \
  --connect=false
VC_RET=$?
set -e
popd >/dev/null
rm -rf "$TMPDIR"
if [[ $VC_RET -ne 0 ]]; then
  red "vcluster create failed (exit $VC_RET)."; exit $VC_RET
fi
green "vCluster $VC created or upgraded."

# generate kubeconfig
VC_KCFG="${KCFG_DIR}/kubeconfig-${DEV}.yaml"
cyan ">> Generating kubeconfig for $VC -> $VC_KCFG"
if ! vcluster connect "$VC" -n "$NS" --update-current=false --print >"$VC_KCFG" 2>/dev/null; then
  red "Failed to generate vCluster kubeconfig."; exit 4
fi
chmod 600 "$VC_KCFG"

# wait API
cyan ">> Waiting for vCluster API ..."
for i in {1..30}; do
  if kubectl --kubeconfig "$VC_KCFG" get --raw='/readyz' >/dev/null 2>&1; then break; fi
  sleep 2
done

# ensure storage in vCluster
cyan ">> Ensuring PVC >=${SIZE_Gi}Gi inside vCluster"
# By default PVC sync virtual->host is enabled; host storage classes are usable; if no SC, create fallback. (See docs.)
SC_COUNT="$(kubectl --kubeconfig "$VC_KCFG" get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SC_COUNT" -eq 0 ]]; then
  yellow "  No StorageClasses visible in vCluster; creating fallback hostPath PV+SC in parent (namespaced)."
  FALLBACK_SC="vc-local"
  FALLBACK_PV="vc-static-pv-${DEV}"
  HOSTPATH="${FALLBACK_HOSTPATH_BASE}/${VC}"
  sudo mkdir -p "$HOSTPATH" || true
  sudo chown "$(id -u)":"$(id -g)" "$HOSTPATH" || true
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${FALLBACK_PV}
  labels:
    vcluster.loft.sh/namespace: ${NS}
spec:
  capacity:
    storage: ${SIZE_Gi}Gi
  volumeMode: Filesystem
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Delete
  storageClassName: ${FALLBACK_SC}
  hostPath:
    path: ${HOSTPATH}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${FALLBACK_SC}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
  # allow syncer to reflect
  sleep 5
else
  echo "  Detected ${SC_COUNT} StorageClass(es) in vCluster:"
  kubectl --kubeconfig "$VC_KCFG" get sc
fi

# create / ensure PVC inside vCluster
cat <<EOF | kubectl --kubeconfig "$VC_KCFG" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vc-shared
  namespace: default
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: ${SIZE_Gi}Gi
EOF

echo "  Waiting for pvc/vc-shared to bind (60s)..."
kubectl --kubeconfig "$VC_KCFG" -n default wait pvc/vc-shared --for=jsonpath='{.status.phase}'=Bound --timeout=60s >/dev/null 2>&1 || yellow "  WARNING: pvc not bound yet; continuing."

green "-------------------------------------------------------------------"
green "vCluster:  $VC"
green "Namespace: $NS"
green "PVC Size:  ${SIZE_Gi}Gi"
green "Kubeconfig: $VC_KCFG"
green "-------------------------------------------------------------------"
