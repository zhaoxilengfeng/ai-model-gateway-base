#!/bin/bash
# downlowd-image.sh — 拉取 llm-d gateway 模式所需镜像到本地 containerd (k8s.io namespace)
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
  if ctr -n k8s.io image ls 2>/dev/null | grep -qF "$original"; then
    echo "  已存在，跳过"
    return
  fi
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

echo "=== 2. vLLM (from Aliyun) ==="
pull_from_aliyun \
  "vllm-openai:v0.23.0" \
  "vllm/vllm-openai:v0.23.0"

echo "=== 3. Agentgateway (from Aliyun) ==="
pull_from_aliyun \
  "agentgateway-controller:v1.3.1" \
  "ghcr.io/agentgateway/controller:v1.3.1"
pull_from_aliyun \
  "agentgateway:v1.3.1" \
  "ghcr.io/agentgateway/agentgateway:v1.3.1"

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep -E "llm-d-router|vllm-openai|agentgateway" | awk '{print $1}'
