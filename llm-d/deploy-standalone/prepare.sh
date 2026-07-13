#!/bin/bash
# prepare.sh — 下载 llm-d standalone 模式依赖到本地
#
# 运行后：
#   /root/deploy/llm-d-standalone/llm-d-router-standalone/   Router chart
#   /root/deploy/llm-d-standalone/gie-v1.5.0.yaml            GIE CRDs manifest
set -e

# 代理默认不启用；需要时通过环境变量传入：
#   HTTPS_PROXY=socks5h://127.0.0.1:1080 bash prepare.sh
PROXY_CMD=""
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  PROXY_CMD="https_proxy=${HTTPS_PROXY}"
elif [[ -n "${https_proxy:-}" ]]; then
  PROXY_CMD="https_proxy=${https_proxy}"
fi


ROUTER_CHART_VERSION="${ROUTER_CHART_VERSION:-v0.9.0}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-standalone}"

CHART_DIR="$DEPLOY_DIR/llm-d-router-standalone"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

mkdir -p "$DEPLOY_DIR"

# ── 1. llm-d-router-standalone chart ─────────────────────────────────────────
echo "=== 1. Pull llm-d-router-standalone chart (${ROUTER_CHART_VERSION}) ==="
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $CHART_DIR）"
else
  ${PROXY_CMD:+$PROXY_CMD }helm pull \
    oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
    --version "$ROUTER_CHART_VERSION" \
    --untar --untardir "$DEPLOY_DIR"
  echo "  下载到 $CHART_DIR"
fi

# ── 2. GIE CRDs manifest ──────────────────────────────────────────────────────
echo "=== 2. Download GIE CRDs (${GAIE_VERSION}) ==="
if [ -f "$GIE_YAML" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $GIE_YAML）"
else
  ${PROXY_CMD:+$PROXY_CMD }curl -sL \
    "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" \
    -o "$GIE_YAML"
  echo "  下载到 $GIE_YAML"
fi

echo ""
echo "=== 准备完成 ==="
echo "  Router chart : $CHART_DIR"
echo "  GIE CRDs     : $GIE_YAML"
echo ""
echo "现在可运行 install.sh："
echo "  bash $(dirname "$0")/install.sh"
