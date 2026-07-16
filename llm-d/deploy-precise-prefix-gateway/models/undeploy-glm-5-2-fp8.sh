#!/bin/bash
# 销毁 GLM-5.2-FP8，释放 8 张 H200 GPU

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 销毁 GLM-5.2-FP8 ==="
bash "${DEPLOY_DIR}/undeploy-model.sh" glm-5-2-fp8

echo ""
echo "=== GPU 已释放，当前可用资源 ==="
kubectl describe node h200-12-3 2>/dev/null | grep -A4 'Allocated resources' || true
