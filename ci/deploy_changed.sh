#!/usr/bin/env bash
# Usage: deploy_changed.sh <kubeconfig> <comma‑list>
set -euo pipefail

export KUBECONFIG="$1"
shift
IFS=',' read -ra SERVICES <<< "$1"

for svc in "${SERVICES[@]}"; do
  manifest="scripts/testbed/${svc}.yaml"
  if [[ -f "${manifest}" ]]; then
    echo "▶︎ Applying ${manifest}"
    kubectl apply -f "${manifest}"
  else
    echo "⚠︎  ${manifest} not found – skipping"
  fi
done
