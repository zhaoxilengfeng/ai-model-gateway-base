#!/bin/bash
# 销毁 qwen25-7b-instruct，释放全部副本占用的 GPU

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 销毁 qwen25-7b-instruct ==="
bash "${DEPLOY_DIR}/undeploy-model.sh" qwen25-7b-instruct

echo ""
echo "=== GPU 已释放，当前可用资源 ==="
kubectl describe node h200-12-3 2>/dev/null | grep -A4 'Allocated resources' || true
