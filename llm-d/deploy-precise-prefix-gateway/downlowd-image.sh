#!/bin/bash
# downlowd-image.sh — 拉取 precise-prefix-cache-routing gateway 模式所需镜像
#
# 相比 standalone 模式新增：
#   agentgateway-controller:v1.3.1  — agentgateway 控制面
#   agentgateway:v1.3.1             — agentgateway 数据面 proxy
#
# 相比 optimized-baseline gateway 新增：
#   vllm-openai-cpu:v0.23.0         — render (tokenizer) service，CPU-only 镜像
set -e

REGISTRY="registry.cn-hangzhou.aliyuncs.com/airouter"

pull_image() {
  local cached="$1" original="$2"
  echo "--- $cached"
  if ctr -n k8s.io image ls 2>/dev/null | grep -qF "$original"; then
    echo "  已存在，跳过"
    return
  fi
  ctr -n k8s.io image pull "$REGISTRY/$cached"
  ctr -n k8s.io image tag  "$REGISTRY/$cached" "$original"
  echo "  imported: $original"
}

echo "=== 1. EPP (from Aliyun) ==="
pull_image \
  "llm-d-router-endpoint-picker:v0.9.0" \
  "ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0"

echo "=== 2. vLLM GPU image (from Aliyun) ==="
pull_image \
  "vllm-openai:v0.23.0" \
  "vllm/vllm-openai:v0.23.0"

echo "=== 3. vLLM CPU image — render/tokenizer service (from Aliyun) ==="
pull_image \
  "vllm-openai-cpu:v0.23.0" \
  "vllm/vllm-openai-cpu:v0.23.0"

echo "=== 4. Agentgateway (from Aliyun) ==="
pull_image \
  "agentgateway-controller:v1.3.1" \
  "ghcr.io/agentgateway/controller:v1.3.1"
pull_image \
  "agentgateway:v1.3.1" \
  "ghcr.io/agentgateway/agentgateway:v1.3.1"

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep -E "llm-d-router|vllm-openai|agentgateway" | awk '{print $1}'
