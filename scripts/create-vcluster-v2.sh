#!/usr/bin/env bash
#
# create-vcluster-v3.sh
#
# Create (or upgrade) a vCluster in a dedicated namespace, ensure networking,
# and provision at least one 5Gi (default) PVC usable from inside the vCluster.
#
# ------------------------------------------------------------------------------
# USAGE:
#   ./create-vcluster-v3.sh <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]
#
# EXAMPLE:
#   ./create-vcluster-v3.sh 2
#   ./create-vcluster-v3.sh 7 10 1.31 my-admin@parent
#
# EXPECTED SIDE EFFECTS (parent cluster):
#   - Ensures br_netfilter + forwarding sysctls (best effort)
#   - Installs Flannel (best effort) if kube-flannel-ds not present
#   - Creates namespace: dev-<ID>
#   - Creates / upgrades vCluster: vcluster-<ID> in namespace dev-<ID>
#   - Writes kubeconfig to: $HOME/vc-kcfg/kubeconfig-<ID>.yaml
#
# EXPECTED SIDE EFFECTS (inside vCluster):
#   - Syncs StorageClasses & PVCs to parent (vcluster values set)
#   - Ensures at least one PVC of SIZE_Gi (default 5) exists ("vc-shared")
#   - If *no* StorageClass exists in vCluster after sync, creates a fallback
#     hostPath PV + SC + PVC trio (small lab use only; not HA).
#
# REQUIREMENTS:
#   - `kubectl` & `vcluster` CLIs installed & in PATH
#   - Working kubeconfig in $HOME/.kube/config with context for parent cluster
#   - Sufficient RBAC to create namespaces + CRDs + helm releases
#
# EXIT CODES:
#   0 success
#   non-zero on fatal error
#
# ------------------------------------------------------------------------------

set -euo pipefail

# ---------- Parse Args ----------
DEV="${1:-}"
if [[ -z "$DEV" ]]; then
  echo "ERROR: Must supply ID. Usage: $0 <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]" >&2
  exit 1
fi
SIZE_Gi="${2:-5}"
K8S_VERSION="${3:-1.32}"
PARENT_CONTEXT="${4:-kubernetes-admin@kubernetes}"

# ---------- Constants / Tunables ----------
NS="dev-${DEV}"
VC="vcluster-${DEV}"

# Where to store generated kubeconfigs (safe dir; avoids vcluster chart name collision)
KCFG_DIR="$HOME/vc-kcfg"
mkdir -p "$KCFG_DIR"

# Flannel manifest
FLANNEL_MANIFEST_URL="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

# Parent kubeconfig (modify if you keep cluster credentials elsewhere)
PARENT_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Fallback storage path on parent node if we must create our own hostPath PV
FALLBACK_HOSTPATH_BASE="/tmp/vc-storage"
mkdir -p "$FALLBACK_HOSTPATH_BASE" || true

# Colored output helpers
cyan()  { printf "\033[0;36m%s\033[0m\n" "$*"; }
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
red()   { printf "\033[0;31m%s\033[0m\n" "$*"; }


# ---------- Preflight ----------
cyan ">> Using parent kubeconfig: $PARENT_KUBECONFIG"
if [[ ! -f "$PARENT_KUBECONFIG" ]]; then
  red "Parent kubeconfig not found: $PARENT_KUBECONFIG"; exit 2
fi
export KUBECONFIG="$PARENT_KUBECONFIG"

# Make sure we are on the *parent* cluster, not already in a vcluster
if ! kubectl config use-context "$PARENT_CONTEXT" >/dev/null 2>&1; then
  yellow "Context '$PARENT_CONTEXT' not found or could not be selected; continuing with current context."
fi

# Validate cluster reachability
if ! kubectl version --short >/dev/null 2>&1; then
  red "kubectl cannot reach parent cluster. Aborting."; exit 3
fi


# ---------- Host Kernel Prereqs (best effort) ----------
cyan ">> Ensuring host kernel params for networking ..."
{
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1    >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv4.ip_forward=1                   >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv6.conf.all.forwarding=1          >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv4.conf.all.promote_secondaries=1 >/dev/null 2>&1 || true
} || true


# ---------- Flannel (best effort) ----------
cyan ">> Checking Flannel CNI ..."
if ! kubectl -n kube-flannel get ds kube-flannel-ds >/dev/null 2>&1; then
  echo "  Installing Flannel CNI DaemonSet (best-effort)."
  if ! kubectl apply --validate=false -f "$FLANNEL_MANIFEST_URL"; then
    yellow "  WARNING: Flannel install failed; continuing (CI mode)."
  fi
else
  echo "  Flannel already present; skipping install."
fi
echo "  Waiting up to 180s for Flannel to roll out ..."
if ! kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=180s >/dev/null 2>&1; then
  yellow "  WARNING: Flannel rollout not confirmed; continuing."
fi


# ---------- Namespace ----------
cyan ">> Ensuring namespace: $NS"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"


# ---------- Create / Upgrade vCluster ----------
cyan ">> Deploying $VC (virtual k8s $K8S_VERSION) in namespace $NS"

# Use a scratch dir to avoid path collisions with 'vcluster' chart name
TMPDIR="$(mktemp -d "/tmp/${VC}-XXXX")"
pushd "$TMPDIR" >/dev/null

# NOTE: enabling storage sync so we can create PVCs inside vcluster that map to parent cluster
set +e
vcluster create "$VC" \
  -n "$NS" \
  --k8s-version "$K8S_VERSION" \
  --upgrade \
  --connect=false \
  --syncer-priority-class="" \
  --set sync.persistentvolumeclaims.enabled=true \
  --set sync.storageclasses.enabled=true \
  --set sync.persistentvolumes.enabled=false \
  --set sync.nodes.enabled=false \
  --set vcluster.imagePullPolicy=IfNotPresent
VC_RET=$?
set -e
popd >/dev/null
rm -rf "$TMPDIR"

if [[ $VC_RET -ne 0 ]]; then
  red "vcluster create failed (exit $VC_RET)."; exit $VC_RET
fi

green "vCluster $VC created or upgraded."


# ---------- Generate vCluster kubeconfig ----------
VC_KCFG="${KCFG_DIR}/kubeconfig-${DEV}.yaml"
cyan ">> Generating kubeconfig for $VC -> $VC_KCFG"

# --print emits a client-go exec plugin kubeconfig that reuses parent cluster auth
if ! vcluster connect "$VC" -n "$NS" --update-current=false --print >"$VC_KCFG" 2>/dev/null; then
  red "Failed to generate kubeconfig via vcluster connect."; exit 4
fi
chmod 600 "$VC_KCFG"

# Quick health ping
cyan ">> Waiting for vCluster API to respond ..."
for i in {1..30}; do
  if kubectl --kubeconfig "$VC_KCFG" version --short >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! kubectl --kubeconfig "$VC_KCFG" version --short >/dev/null 2>&1; then
  yellow "WARNING: vCluster API did not respond in time; continuing (CI)."
fi


# ---------- Ensure Storage in vCluster ----------
cyan ">> Ensuring storage (>=${SIZE_Gi}Gi) inside $VC"

# Are there any StorageClasses visible in the vCluster?
SC_COUNT="$(kubectl --kubeconfig "$VC_KCFG" get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SC_COUNT" -eq 0 ]]; then
  yellow "  No StorageClasses found in vCluster; creating fallback static hostPath PV+SC."
  FALLBACK_SC="vc-local"
  FALLBACK_PV="vc-static-pv"
  HOSTPATH="${FALLBACK_HOSTPATH_BASE}/${VC}"
  mkdir -p "$HOSTPATH" || true

  cat <<EOF | kubectl --kubeconfig "$VC_KCFG" apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${FALLBACK_PV}
spec:
  capacity:
    storage: ${SIZE_Gi}Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
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

else
  echo "  Detected existing StorageClasses in vCluster:"
  kubectl --kubeconfig "$VC_KCFG" get sc
  # Mark first SC as default if none marked (best effort)
  if ! kubectl --kubeconfig "$VC_KCFG" get sc -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{" "}{end}' 2>/dev/null | grep -q true; then
    DEF_SC="$(kubectl --kubeconfig "$VC_KCFG" get sc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo default)"
    yellow "  Marking $DEF_SC as default."
    kubectl --kubeconfig "$VC_KCFG" patch sc "$DEF_SC" \
      --type=merge \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
  fi
fi

# Create (or ensure) a PVC in the *vCluster* namespace "default" named vc-shared
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

# Wait up to 60s for PVC bind (best effort)
echo "  Waiting for PVC vc-shared to bind ..."
if ! kubectl --kubeconfig "$VC_KCFG" -n default wait pvc/vc-shared --for=jsonpath='{.status.phase}'=Bound --timeout=60s >/dev/null 2>&1; then
  yellow "  WARNING: PVC vc-shared not bound after 60s; continuing."
fi


# ---------- Summary ----------
green "-------------------------------------------------------------------"
green "vCluster:  $VC"
green "Namespace: $NS"
green "K8s Ver:   $K8S_VERSION"
green "PVC Size:  ${SIZE_Gi}Gi"
green "Kubeconfig written to: $VC_KCFG"
green "-------------------------------------------------------------------"
echo
echo "You can copy this kubeconfig back to Jenkins and run:"
echo "  kubectl --kubeconfig kubeconfig-${DEV}.yaml get pods -A"
echo
