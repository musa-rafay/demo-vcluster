#!/usr/bin/env bash
#
# create-vcluster-v2.sh  eg. musa001
# ------------------------------
# Works with vcluster CLI 0.26.x 
# ------------------------------

set -euo pipefail

### -------- USER PARAMETERS -------------------------------------------------
DEV="${1:-}"
[ -z "$DEV" ] && { echo "Usage: $0 <developer-name>"; exit 1; }

NS="dev-${DEV}"
VC="vcluster-${DEV}"
VC_K8S_VER="1.32"

KCFG_DIR="$HOME/vc-kcfg"
KCFG_FILE="${KCFG_DIR}/kubeconfig-${DEV}.yaml"
VCLUSTER_HOME="$HOME/.cache/vcluster"
FLANNEL_MANIFEST_URL="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
### --------------------------------------------------------------------------

command -v vcluster >/dev/null || { echo " vcluster CLI not found"; exit 1; }
vcluster --version | grep -qE '0\.2[6-9]' || {
  echo "  vcluster 0.26+ required (current: $(vcluster --version))"; exit 1; }
command -v jq >/dev/null || { echo " jq missing: sudo apt -y install jq"; exit 1; }

mkdir -p "$KCFG_DIR" "$VCLUSTER_HOME"

###############################################################################
# 1. Host kernel prerequisites
###############################################################################
echo "  Ensuring br_netfilter & forwarding sysctls ..."
sudo modprobe br_netfilter || true
sudo tee /etc/sysctl.d/99-k8s-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --quiet --system

###############################################################################
# 2. Flannel CNI (host)
###############################################################################
if ! kubectl -n kube-flannel get ds kube-flannel-ds >/dev/null 2>&1; then
  echo "  Installing Flannel CNI DaemonSet (best-effort)"
  if ! kubectl apply --validate=false -f "${FLANNEL_MANIFEST_URL}"; then
    echo "  WARNING: Flannel install failed; continuing anyway (CI mode)."
  fi
else
  echo "  Flannel already present; skipping install."
fi

###############################################################################
# 3. Namespace & vCluster create/upgrade
###############################################################################
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "  Deploying ${VC} (k8s ${VC_K8S_VER}) in ${NS}"
vcluster create "$VC" \
        -n "$NS" \
        --upgrade \
        --connect=false

kubectl -n "$NS" rollout status sts "$VC" --timeout=180s

###############################################################################
# 4. Port‑forward (background) & kube‑config
###############################################################################
echo "  Starting background port‑forward and writing kube‑config …"
vcluster connect "$VC" -n "$NS" \
        --background-proxy \
        --local-port 0 \
        --kube-config "$KCFG_FILE" \
        
export KUBECONFIG="$KCFG_FILE"

###############################################################################
# 5. Local‑path provisioner inside the vCluster
###############################################################################
echo "🗄️  Installing local-path-provisioner inside the vCluster …"
kubectl apply --validate=false -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=90s

###############################################################################
# 6. All done
###############################################################################
echo
echo "  vCluster '${VC}' READY for ${DEV}"
echo "    KUBECONFIG:  ${KCFG_FILE}"
echo
echo "Next steps:"
echo "  export KUBECONFIG=${KCFG_FILE}"
echo "  kubectl get nodes          # should list 'vcluster-node'"
echo "  kubectl create ns demo && helm install …"
