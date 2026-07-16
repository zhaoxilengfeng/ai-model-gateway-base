#!/bin/bash
# 启动 qwen25-7b-instruct（vLLM，每副本 1×H200，默认 8 副本占满整机）
#
# 注意：GLM-5.2-FP8 占用整机全部 GPU，启动前需先销毁 GLM
# 可通过 REPLICAS 环境变量调整副本数，例如: REPLICAS=4 bash start-qwen25-7b-instruct.sh

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export REPLICAS="${REPLICAS:-8}"

bash "${DEPLOY_DIR}/deploy-model.sh" qwen25-7b-instruct \
  /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct

echo ""
echo "=== 测试命令 ==="
echo "  curl http://116.198.67.18:31273/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"qwen25-7b-instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":100}'"
