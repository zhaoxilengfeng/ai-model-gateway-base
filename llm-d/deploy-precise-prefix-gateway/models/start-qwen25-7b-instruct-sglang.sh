#!/bin/bash
# 启动 qwen25-7b-instruct（sglang，8 副本，各 1×H200）
# 注意：与 vLLM 版共占 8 张 GPU，不可同时运行

set -e
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export REPLICAS="${REPLICAS:-8}"
bash "${DEPLOY_DIR}/deploy-qwen-sglang.sh"
