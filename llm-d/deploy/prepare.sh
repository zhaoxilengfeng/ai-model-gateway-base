#!/bin/bash
# prepare.sh — 下载 llm-d v0.8.1 依赖的外部文件和 chart 到本地
#
# 运行后：
#   /root/deploy/llm-d/gateway-api/standard-install.yaml   Gateway API CRDs
#   /root/deploy/llm-d/llm-d-chart/                        llm-d Helm chart（已去除 kubeVersion 限制）
#
# 两个路径即 install.sh 中对应变量的默认值。
set -e

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"
LLM_D_CHART_VERSION="${LLM_D_CHART_VERSION:-1.0.23}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d}"

GATEWAY_API_DIR="$DEPLOY_DIR/gateway-api"
GATEWAY_API_YAML="$GATEWAY_API_DIR/standard-install.yaml"
LLM_D_CHART_DIR="$DEPLOY_DIR/llm-d-chart"

mkdir -p "$GATEWAY_API_DIR"

# ── 1. Gateway API CRDs ───────────────────────────────────────────────────────
echo "=== 1. Download Gateway API CRDs (${GATEWAY_API_VERSION}) ==="
if [ -f "$GATEWAY_API_YAML" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $GATEWAY_API_YAML）"
else
  https_proxy=socks5h://127.0.0.1:1080 curl -sL \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    -o "$GATEWAY_API_YAML"
  echo "  下载到 $GATEWAY_API_YAML"
fi

# ── 2. llm-d Helm chart ───────────────────────────────────────────────────────
echo "=== 2. Pull llm-d chart (${LLM_D_CHART_VERSION}) ==="
if [ -f "$LLM_D_CHART_DIR/Chart.yaml" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $LLM_D_CHART_DIR）"
else
  # 优先从本地 helm cache 提取，避免网络问题
  CACHED_TGZ="$HOME/.cache/helm/repository/llm-d-${LLM_D_CHART_VERSION}.tgz"
  mkdir -p "$DEPLOY_DIR/llm-d-chart-src"
  if [ -f "$CACHED_TGZ" ]; then
    echo "  使用本地缓存: $CACHED_TGZ"
    tar -xzf "$CACHED_TGZ" -C "$DEPLOY_DIR/llm-d-chart-src"
  else
    https_proxy=socks5h://127.0.0.1:1080 helm repo update llm-d 2>/dev/null || true
    helm pull llm-d/llm-d \
      --version "$LLM_D_CHART_VERSION" \
      --untar --untardir "$DEPLOY_DIR/llm-d-chart-src"
  fi
  # 去除 kubeVersion 限制（K8s 1.35 实际兼容，但 chart 声明 >= 1.30）
  mv "$DEPLOY_DIR/llm-d-chart-src/llm-d" "$LLM_D_CHART_DIR"
  sed -i '/^kubeVersion:/d' "$LLM_D_CHART_DIR/Chart.yaml"
  rm -rf "$DEPLOY_DIR/llm-d-chart-src"
  echo "  就绪: $LLM_D_CHART_DIR"
fi

# ── 验证 ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== 准备完成 ==="
echo "  Gateway API CRDs : $GATEWAY_API_YAML"
echo "  llm-d chart      : $LLM_D_CHART_DIR"
echo ""
echo "现在可运行 install.sh："
echo "  bash $(dirname "$0")/install.sh"
