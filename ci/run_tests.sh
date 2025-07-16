 #!/usr/bin/env bash
set -euo pipefail

IFS=',' read -ra SERVICES <<< "$1"

for svc in "${SERVICES[@]}"; do
  echo "🧪 Waiting for Deployment/${svc} to become ready..."
  kubectl rollout status deploy/${svc} --timeout=120s
  echo "✅  ${svc} ready"
done
