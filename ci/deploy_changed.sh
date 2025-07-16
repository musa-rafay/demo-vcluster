#!/usr/bin/env bash
# Usage: deploy_changed.sh <kube‑context> "svc1,svc2"
# Applies each service’s k8s manifests into the vcluster
set -euo pipefail

CTX="${1:?context missing}"
SVC_CSV="${2:-}"
IFS=',' read -ra SVC_ARR <<<"${SVC_CSV}"

for svc in "${SVC_ARR[@]}"; do
  MAN_DIR="${svc}/k8s"
  if [[ -d "${MAN_DIR}" ]]; then
    echo "▶︎ Deploying ${svc}"
    kubectl --context "${CTX}" apply -f "${MAN_DIR}"
  else
    echo "⚠︎  ${MAN_DIR} not found – skipping"
  fi
done
