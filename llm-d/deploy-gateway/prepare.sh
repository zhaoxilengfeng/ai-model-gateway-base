#!/bin/bash
# prepare.sh — 下载 llm-d gateway 模式依赖到本地
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
AGENTGATEWAY_VERSION="${AGENTGATEWAY_VERSION:-v1.3.1}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-gateway}"

CHART_DIR="$DEPLOY_DIR/llm-d-router-gateway"
AGW_DEPLOY_DIR="$DEPLOY_DIR/agentgateway"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

AGW_CRD_DIR="$DEPLOY_DIR/agentgateway-crds"

mkdir -p "$DEPLOY_DIR"

# ── 1. llm-d-router-gateway chart ────────────────────────────────────────────
echo "=== 1. Pull llm-d-router-gateway chart (${ROUTER_CHART_VERSION}) ==="
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $CHART_DIR）"
else
  ${PROXY_CMD:+$PROXY_CMD }helm pull \
    oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
    --version "$ROUTER_CHART_VERSION" \
    --untar --untardir "$DEPLOY_DIR"
  echo "  下载到 $CHART_DIR"
fi

# ── 2. Agentgateway chart ─────────────────────────────────────────────────────
echo "=== 2. Pull agentgateway chart (${AGENTGATEWAY_VERSION}) ==="
if grep -q "version: ${AGENTGATEWAY_VERSION}" "$AGW_DEPLOY_DIR/agentgateway/Chart.yaml" 2>/dev/null; then
  echo "  已存在 ${AGENTGATEWAY_VERSION}，跳过"
else
  mkdir -p "$AGW_DEPLOY_DIR"
  rm -rf "$AGW_DEPLOY_DIR/agentgateway"
  ${PROXY_CMD:+$PROXY_CMD }helm pull oci://cr.agentgateway.dev/charts/agentgateway \
    --version "$AGENTGATEWAY_VERSION" \
    --untar --untardir "$AGW_DEPLOY_DIR"
  echo "  下载到 $AGW_DEPLOY_DIR/agentgateway"
fi

# ── 3. GIE CRDs manifest ──────────────────────────────────────────────────────
echo "=== 3. Download GIE CRDs (${GAIE_VERSION}) ==="
if [ -f "$GIE_YAML" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $GIE_YAML）"
else
  ${PROXY_CMD:+$PROXY_CMD }curl -sL \
    "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" \
    -o "$GIE_YAML"
  echo "  下载到 $GIE_YAML"
fi

# ── 4. Agentgateway CRDs ──────────────────────────────────────────────────────
echo "=== 4. Download Agentgateway CRDs (${AGENTGATEWAY_VERSION}) ==="
if ls "$AGW_CRD_DIR"/*.yaml &>/dev/null; then
  echo "  已存在，跳过（如需重新下载请删除 $AGW_CRD_DIR）"
else
  mkdir -p "$AGW_CRD_DIR"
  AGW_CRD_BASE="https://raw.githubusercontent.com/agentgateway/agentgateway/${AGENTGATEWAY_VERSION}/controller/install/helm/agentgateway-crds/templates"
  for crd in agentgateway.dev_agentgatewaybackends.yaml agentgateway.dev_agentgatewayparameters.yaml agentgateway.dev_agentgatewaypolicies.yaml; do
    ${PROXY_CMD:+$PROXY_CMD }curl -sf "$AGW_CRD_BASE/$crd" -o "$AGW_CRD_DIR/$crd"
    echo "  下载: $crd"
  done
fi

echo ""
echo "=== 准备完成 ==="
echo "  Router chart      : $CHART_DIR"
echo "  Agentgateway chart: $AGW_DEPLOY_DIR/agentgateway"
echo "  Agentgateway CRDs : $AGW_CRD_DIR"
echo "  GIE CRDs          : $GIE_YAML"
echo ""
echo "现在可运行 install.sh："
echo "  bash $(dirname "$0")/install.sh"
