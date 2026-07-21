#!/bin/bash
# start-glm4-9b.sh — 启动 GLM-4-9B（vLLM，2 副本，各 1×H200）
#
# GLM-4-9B 参数量 9B，单卡 H200 可运行
# 默认 2 副本（节省 GPU，与 qwen 共存时可降低 qwen 副本腾空间）
# 注意：需要先确保有足够 GPU（kubectl get node h200-12-3 -o jsonpath=...）

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export REPLICAS="${REPLICAS:-2}"

bash "${DEPLOY_DIR}/deploy-model.sh" glm-4-9b \
  /home/data/model/glm-4-9b-chat

echo ""
echo "=== 测试命令 ==="
echo "  curl http://116.198.67.18:31273/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"glm-4-9b\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":50}'"
