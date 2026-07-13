#!/bin/bash
# downlowd-image.sh — 拉取 precise-prefix-cache-routing 所需镜像
#
# 额外镜像（相比 optimized-baseline）：
#   vllm/vllm-openai-cpu:v0.23.0  — render (tokenizer) service，无 GPU，CPU-only 镜像
#
# vLLM model server 镜像与 deploy-gateway/deploy-standalone 相同（vllm/vllm-openai:v0.23.0）
set -e

REGISTRY="registry.cn-hangzhou.aliyuncs.com/airouter"
USER="731553103@qq.com"
PASS=$(cat ~/.docker/config.json | python3 -c "
import json,sys,base64
d=json.load(sys.stdin)
auth=d['auths']['registry.cn-hangzhou.aliyuncs.com']['auth']
print(base64.b64decode(auth).decode().split(':',1)[1])
")

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

pull_from_aliyun() {
  local cached="$1" original="$2"
  local tarfile="$TMP/${cached//:/-}.tar"
  echo "--- $cached"
  skopeo copy \
    --override-os linux --override-arch amd64 \
    --src-creds "$USER:$PASS" \
    "docker://$REGISTRY/$cached" \
    "docker-archive:$tarfile:$original"
  ctr -n k8s.io image import "$tarfile"
  echo "  imported: $original"
}

echo "=== 1. EPP (from Aliyun) ==="
pull_from_aliyun \
  "llm-d-router-endpoint-picker:v0.9.0" \
  "ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0"

echo "=== 2. vLLM GPU image (from Aliyun) ==="
pull_from_aliyun \
  "vllm-openai:v0.23.0" \
  "vllm/vllm-openai:v0.23.0"

echo "=== 3. vLLM CPU image — render/tokenizer service (from Aliyun) ==="
pull_from_aliyun \
  "vllm-openai-cpu:v0.23.0" \
  "vllm/vllm-openai-cpu:v0.23.0"

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep -E "llm-d-router|vllm-openai" | awk '{print $1}'
