#!/bin/bash
# undeploy-qwen-sglang.sh — 销毁 sglang 版 qwen25-7b-instruct

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 销毁 qwen25-7b-instruct-sglang ==="
bash "${DEPLOY_DIR}/undeploy-model.sh" qwen25-7b-instruct-sglang

echo ""
echo "=== GPU 已释放 ==="
kubectl describe node h200-12-3 2>/dev/null | grep -A4 'Allocated resources' || true
