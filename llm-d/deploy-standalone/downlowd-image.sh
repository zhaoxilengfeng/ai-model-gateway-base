#!/bin/bash
# downlowd-image.sh — 拉取 llm-d standalone 模式所需镜像到本地 containerd (k8s.io namespace)
#
# 镜像来源：
#   EPP、vLLM  → 阿里云缓存
#   envoy      → docker hub（需走代理：https_proxy=socks5h://127.0.0.1:1080）
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

echo "=== 2. vLLM (from Aliyun) ==="
pull_from_aliyun \
  "vllm-openai:v0.8.5" \
  "vllm/vllm-openai:v0.8.5"

echo "=== 3. Envoy distroless-v1.33.2 (需要代理或本地已有) ==="
if ctr -n k8s.io image ls 2>/dev/null | grep -q "envoy:distroless-v1.33.2"; then
  echo "  已存在，跳过"
else
  echo "  从 docker hub 拉取（需代理）..."
  https_proxy=socks5h://127.0.0.1:1080 ctr -n k8s.io image pull \
    docker.io/envoyproxy/envoy:distroless-v1.33.2
fi

echo ""
echo "=== 镜像就绪 ==="
ctr -n k8s.io image ls | grep -E "llm-d-router|vllm-openai|envoy:distroless" | awk '{print $1}'
