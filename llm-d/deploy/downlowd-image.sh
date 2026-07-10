#!/bin/bash
# downlowd-image.sh — 从阿里云缓存拉取 llm-d v0.8.1 所需镜像到本地 containerd（k8s.io namespace）
# 拉取后 retag 为原始镜像名，部署无需修改任何配置
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

declare -A images=(
  # llm-d 核心（v0.8.1）
  ["llm-d-router-endpoint-picker:v0.9.0"]="ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0"
  ["llm-d-router-disagg-sidecar:v0.9.0"]="ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0"
  ["vllm-openai:v0.23.0"]="vllm/vllm-openai:v0.23.0"
)

for cached in "${!images[@]}"; do
  original="${images[$cached]}"
  tarfile="$TMP/${cached//:/-}.tar"
  echo "--- $cached -> $original"
  skopeo copy \
    --override-os linux --override-arch amd64 \
    --src-creds "$USER:$PASS" \
    "docker://$REGISTRY/$cached" \
    "docker-archive:$tarfile:$original"
  ctr -n k8s.io image import "$tarfile"
  echo "  imported: $original"
done

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep -E "llm-d|vllm" | awk '{print $1}'
