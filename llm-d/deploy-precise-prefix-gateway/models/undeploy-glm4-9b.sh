#!/bin/bash
# undeploy-glm4-9b.sh — 销毁 GLM-4-9B，释放 GPU

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 销毁 GLM-4-9B ==="
bash "${DEPLOY_DIR}/undeploy-model.sh" glm-4-9b

echo ""
echo "=== GPU 已释放 ==="
kubectl describe node h200-12-3 2>/dev/null | grep -A4 'Allocated resources' || true
