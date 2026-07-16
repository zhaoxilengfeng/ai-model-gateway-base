#!/bin/bash
# 销毁 GLM-5.2-FP8，释放 8 张 H200 GPU
#
# 销毁后若需部署其他模型（如 qwen25-7b-instruct），GPU 即可使用

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"

echo "=== 销毁 GLM-5.2-FP8 ==="
bash "${DEPLOY_DIR}/undeploy-model.sh" glm-5-2-fp8

echo ""
echo "=== GPU 已释放，当前可用资源 ==="
kubectl describe node h200-12-3 2>/dev/null | grep -A4 'Allocated resources' || true
