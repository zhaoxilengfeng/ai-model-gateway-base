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
GHCR_MIRROR="${GHCR_MIRROR:-ghcr.nju.edu.cn}"

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

pull_ghcr_image() {
  local image="$1" original="$2"
  echo "--- $image"
  if ctr -n k8s.io image ls 2>/dev/null | grep -qF "$original"; then
    echo "  已存在，跳过"
    return
  fi
  ctr -n k8s.io image pull "${GHCR_MIRROR}/${image}"
  ctr -n k8s.io image tag  "${GHCR_MIRROR}/${image}" "$original"
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

echo "=== 4. Agentgateway (from ghcr mirror: ${GHCR_MIRROR}) ==="
pull_ghcr_image \
  "agentgateway/controller:v1.3.1" \
  "ghcr.io/agentgateway/controller:v1.3.1"
pull_ghcr_image \
  "agentgateway/agentgateway:v1.3.1" \
  "ghcr.io/agentgateway/agentgateway:v1.3.1"

# kubelet 拉取镜像时会补全 docker.io/ 前缀，需提前打 tag 避免重复拉取
echo "=== 5. Add docker.io prefix tags (for kubelet) ==="
for img in vllm/vllm-openai:v0.23.0 vllm/vllm-openai-cpu:v0.23.0; do
  if ! ctr -n k8s.io image ls 2>/dev/null | grep -qF "docker.io/$img"; then
    ctr -n k8s.io image tag "$img" "docker.io/$img"
    echo "  tagged: docker.io/$img"
  else
    echo "  已存在: docker.io/$img"
  fi
done

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep -E "llm-d-router|vllm-openai|agentgateway" | awk '{print $1}'
