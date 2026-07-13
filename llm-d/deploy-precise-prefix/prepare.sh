#!/bin/bash
# prepare.sh — 下载 precise-prefix-cache-routing 所需 Helm chart 依赖
set -e

ROUTER_CHART_VERSION="${ROUTER_CHART_VERSION:-v0.9.0}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-precise-prefix}"

CHART_DIR="$DEPLOY_DIR/llm-d-router-standalone"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

mkdir -p "$DEPLOY_DIR"

# ── 1. llm-d-router-standalone chart ─────────────────────────────────────────
echo "=== 1. Pull llm-d-router-standalone chart (${ROUTER_CHART_VERSION}) ==="
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $CHART_DIR）"
else
  https_proxy=socks5h://127.0.0.1:1080 helm pull \
    oci://ghcr.io/llm-d/charts/llm-d-router-standalone \
    --version "$ROUTER_CHART_VERSION" \
    --untar --untardir "$DEPLOY_DIR"
  echo "  下载到 $CHART_DIR"
fi

# ── 2. GIE CRDs manifest ──────────────────────────────────────────────────────
echo "=== 2. Download GIE CRDs (${GAIE_VERSION}) ==="
if [ -f "$GIE_YAML" ]; then
  echo "  已存在，跳过"
else
  https_proxy=socks5h://127.0.0.1:1080 curl -sL \
    "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" \
    -o "$GIE_YAML"
  echo "  下载到 $GIE_YAML"
fi

echo ""
echo "=== 准备完成 ==="
echo "  Router chart : $CHART_DIR"
echo "  GIE CRDs     : $GIE_YAML"
echo ""
echo "现在可运行 install.sh"
