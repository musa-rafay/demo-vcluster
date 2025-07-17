#!/usr/bin/env bash
#
# create-vcluster-v4.sh
#
# Create (or upgrade) a vCluster in a dedicated namespace, ensure networking,
# sync storage resources, and guarantee at least one >=5Gi PVC is available
# inside the vCluster (fallback hostPath if no default SC).
#
# ---------------------------------------------------------------------------
# USAGE:
#   ./create-vcluster-v4.sh <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]
#
# EXAMPLES:
#   ./create-vcluster-v4.sh 2
#   ./create-vcluster-v4.sh 7 10 1.31 my-admin@parent
#
# SIDE EFFECTS (parent cluster):
#   - Best-effort kernel param tuning (netfilter/forwarding)
#   - Best-effort Flannel install (if missing)
#   - Namespace dev-<ID> ensured
#   - vCluster vcluster-<ID> installed/upgraded in dev-<ID>
#   - Optional fallback hostPath PV/SC in dev-<ID> (only if needed for storage)
#   - Kubeconfig written: $HOME/vc-kcfg/kubeconfig-<ID>.yaml
#
# SIDE EFFECTS (inside vCluster):
#   - StorageClasses + PVCs synced from parent (we enable PV sync too)
#   - PVC `vc-shared` (SIZE_Gi) ensured in default ns
#
# REQUIREMENTS:
#   - kubectl + vcluster CLIs in PATH
#   - Valid kubeconfig to parent cluster (defaults $HOME/.kube/config)
#   - RBAC to create namespace, CRDs, and Helm installs in parent
#
# EXIT CODES:
#   0 success
#   non-zero on fatal error
# ---------------------------------------------------------------------------

set -euo pipefail

# ----- Args ------------------------------------------------------------------
DEV="${1:-}"
if [[ -z "$DEV" ]]; then
  echo "ERROR: Must supply ID. Usage: $0 <ID> [SIZE_Gi=5] [K8S_VERSION=1.32] [PARENT_CONTEXT=kubernetes-admin@kubernetes]" >&2
  exit 1
fi
SIZE_Gi="${2:-5}"
K8S_VERSION="${3:-1.32}"
PARENT_CONTEXT="${4:-kubernetes-admin@kubernetes}"

# ----- Derived names ----------------------------------------------------------
NS="dev-${DEV}"
VC="vcluster-${DEV}"

# where to stash kubeconfigs we generate for Jenkins to scp
KCFG_DIR="$HOME/vc-kcfg"
mkdir -p "$KCFG_DIR"

# manifest + dirs
FLANNEL_MANIFEST_URL="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
FALLBACK_HOSTPATH_BASE="/tmp/vc-storage"        # parent node path for static PV fallback
mkdir -p "$FALLBACK_HOSTPATH_BASE" || true

# honor incoming KUBECONFIG else default
PARENT_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# ----- Output helpers ---------------------------------------------------------
cyan()  { printf "\033[0;36m%s\033[0m\n" "$*"; }
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
red()   { printf "\033[0;31m%s\033[0m\n" "$*"; }

# ----- Preflight: kubeconfig & cluster reachability ---------------------------
cyan ">> Using parent kubeconfig: $PARENT_KUBECONFIG"
if [[ ! -f "$PARENT_KUBECONFIG" ]]; then
  red "Parent kubeconfig not found: $PARENT_KUBECONFIG"; exit 2
fi
export KUBECONFIG="$PARENT_KUBECONFIG"

# ensure parent context (best effort)
if ! kubectl config use-context "$PARENT_CONTEXT" >/dev/null 2>&1; then
  yellow "Context '$PARENT_CONTEXT' not found or could not be selected; continuing with current context."
fi

# robust reachability check (do NOT use --short; not supported everywhere)
cyan ">> Verifying parent cluster reachability ..."
if ! kubectl get --raw='/healthz' >/dev/null 2>&1; then
  # fallback to get nodes
  if ! kubectl get nodes >/dev/null 2>&1; then
    red "Cannot reach parent cluster (failed /healthz & get nodes). Aborting."
    exit 3
  fi
fi
green "Parent cluster reachable."

# ----- Host kernel params (best effort) ---------------------------------------
cyan ">> Ensuring host kernel params for networking ..."
{
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1    >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv4.ip_forward=1                   >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv6.conf.all.forwarding=1          >/dev/null 2>&1 || true
  sudo sysctl -w net.ipv4.conf.all.promote_secondaries=1 >/dev/null 2>&1 || true
} || true

# ----- Flannel (best effort) --------------------------------------------------
cyan ">> Checking Flannel CNI ..."
if ! kubectl -n kube-flannel get ds kube-flannel-ds >/dev/null 2>&1; then
  echo "  Installing Flannel CNI DaemonSet (best-effort)."
  if ! kubectl apply --validate=false -f "$FLANNEL_MANIFEST_URL"; then
    yellow "  WARNING: Flannel install failed; continuing (CI mode)."
  fi
else
  echo "  Flannel already present; skipping install."
fi
echo "  Waiting up to 180s for Flannel rollout ..."
if ! kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=180s >/dev/null 2>&1; then
  yellow "  WARNING: Flannel rollout not confirmed; continuing."
fi

# ----- Namespace --------------------------------------------------------------
cyan ">> Ensuring namespace: $NS"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# ----- vCluster Create / Upgrade ----------------------------------------------
cyan ">> Deploying $VC (virtual k8s $K8S_VERSION) in namespace $NS"

# scratch dir to dodge chart name collisions
TMPDIR="$(mktemp -d "/tmp/${VC}-XXXX")"
pushd "$TMPDIR" >/dev/null

# Create / upgrade (non-fatal if chart exists; vcluster handles upgrade)
# enable PVC + StorageClass sync; also enable PV sync so bound volumes reflect parent state
set +e
vcluster create "$VC" \
  -n "$NS" \
  --upgrade \
  --connect=false \
  --syncer-priority-class="" \
  --set sync.persistentvolumeclaims.enabled=true \
  --set sync.storageclasses.enabled=true \
  --set sync.persistentvolumes.enabled=true \
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

# ----- Generate vCluster kubeconfig -------------------------------------------
VC_KCFG="${KCFG_DIR}/kubeconfig-${DEV}.yaml"
cyan ">> Generating kubeconfig for $VC -> $VC_KCFG"
if ! vcluster connect "$VC" -n "$NS" --update-current=false --print >"$VC_KCFG" 2>/dev/null; then
  red "Failed to generate kubeconfig via vcluster connect."; exit 4
fi
chmod 600 "$VC_KCFG"

# Wait briefly for API ready
cyan ">> Waiting for vCluster API ..."
for i in {1..30}; do
  if kubectl --kubeconfig "$VC_KCFG" get --raw='/readyz' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# ----- Ensure Storage in vCluster ---------------------------------------------
cyan ">> Ensuring storage (>=${SIZE_Gi}Gi) inside $VC"

# Count SC in vCluster
SC_COUNT="$(kubectl --kubeconfig "$VC_KCFG" get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SC_COUNT" -eq 0 ]]; then
  yellow "  No StorageClasses visible in vCluster after sync."
  yellow "  Creating fallback static hostPath PV/SC in parent namespace $NS."

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
    vcluster.io/ns: ${NS}
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

  # Give the syncer a moment to reflect SC into vCluster
  sleep 5
else
  echo "  Detected $(echo $SC_COUNT) StorageClass(es) in vCluster:"
  kubectl --kubeconfig "$VC_KCFG" get sc
  # ensure at least one default
  if ! kubectl --kubeconfig "$VC_KCFG" get sc -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{" "}{end}' 2>/dev/null | grep -q true; then
    DEF_SC="$(kubectl --kubeconfig "$VC_KCFG" get sc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo default)"
    yellow "  Marking $DEF_SC as default."
    kubectl --kubeconfig "$VC_KCFG" patch sc "$DEF_SC" \
      --type=merge \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
  fi
fi

# Create a PVC inside the vCluster (default ns)
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

echo "  Waiting for PVC vc-shared to bind (60s max) ..."
if ! kubectl --kubeconfig "$VC_KCFG" -n default wait pvc/vc-shared --for=jsonpath='{.status.phase}'=Bound --timeout=60s >/dev/null 2>&1; then
  yellow "  WARNING: PVC vc-shared not bound yet; continuing."
fi

# ----- Summary ----------------------------------------------------------------
green "-------------------------------------------------------------------"
green "vCluster:  $VC"
green "Namespace: $NS"
green "K8s Ver:   $K8S_VERSION"
green "PVC Size:  ${SIZE_Gi}Gi"
green "Kubeconfig written to: $VC_KCFG"
green "-------------------------------------------------------------------"
echo
echo "Use:"
echo "  kubectl --kubeconfig $VC_KCFG get pods -A"
echo
