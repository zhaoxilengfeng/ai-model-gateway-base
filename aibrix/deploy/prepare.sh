#!/bin/bash
# prepare.sh — 为 install.sh 准备 Helm chart 目录
#
# 运行后：
#   /root/aibrix/                              AIBrix 源码（含 dist/chart）
#   /tmp/envoy-gateway/charts/gateway-helm/    Envoy Gateway Helm chart
#
# 两个路径即 install.sh 中 AIBRIX_CHART_DIR / ENVOY_GATEWAY_CHART_DIR 的默认值。
set -e

AIBRIX_VERSION="${AIBRIX_VERSION:-v0.7.0}"
EG_VERSION="${EG_VERSION:-v1.2.8}"

AIBRIX_SRC_DIR="${AIBRIX_SRC_DIR:-/root/deploy/aibrix}"
EG_CHART_DIR="${EG_CHART_DIR:-/root/deploy/envoy-gateway}"

# ── 1. AIBrix 源码 ────────────────────────────────────────────────────────────
echo "=== 1. Clone AIBrix ${AIBRIX_VERSION} ==="
if [ -d "$AIBRIX_SRC_DIR/.git" ]; then
  echo "  已存在，跳过 clone（如需重新拉取请删除 $AIBRIX_SRC_DIR）"
else
  git clone --depth=1 --branch "$AIBRIX_VERSION" \
    https://github.com/vllm-project/aibrix.git \
    "$AIBRIX_SRC_DIR"
fi

# ── 2. 生成 Helm chart（make helm-chart 将 dist/chart/ 生成到 AIBRIX_SRC_DIR/dist/chart）
echo "=== 2. Build AIBrix Helm chart ==="
CHART_DIR="$AIBRIX_SRC_DIR/dist/chart"
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  echo "  dist/chart 已存在，跳过 make（如需重建请删除 $CHART_DIR）"
else
  cd "$AIBRIX_SRC_DIR"
  make helm-chart
  cd - > /dev/null
fi

# ── 3. Envoy Gateway 源码（chart 在 charts/gateway-helm/）─────────────────────
echo "=== 3. Clone Envoy Gateway ${EG_VERSION} ==="
EG_GATEWAY_HELM_DIR="$EG_CHART_DIR/charts/gateway-helm"
if [ -d "$EG_CHART_DIR/.git" ]; then
  echo "  已存在，跳过 clone（如需重新拉取请删除 $EG_CHART_DIR）"
else
  git clone --depth=1 --branch "$EG_VERSION" \
    https://github.com/envoyproxy/gateway.git \
    "$EG_CHART_DIR"
fi

# ── 4. 生成 values.yaml（install.sh 里再次生成，这里提前验证模板存在）
echo "=== 4. Verify Envoy Gateway values template ==="
TMPL="$EG_GATEWAY_HELM_DIR/values.tmpl.yaml"
if [ ! -f "$TMPL" ]; then
  echo "  WARNING: values.tmpl.yaml 不存在，install.sh 中的 sed 步骤将失败"
  echo "  请检查 chart 版本或手动创建 $TMPL"
fi

echo ""
echo "=== 准备完成 ==="
echo "  AIBrix chart  : $CHART_DIR"
echo "  Envoy GW chart: $EG_GATEWAY_HELM_DIR"
echo ""
echo "现在可运行 install.sh："
echo "  AIBRIX_CHART_DIR=$CHART_DIR \\"
echo "  ENVOY_GATEWAY_CHART_DIR=$EG_GATEWAY_HELM_DIR \\"
echo "  bash $(dirname "$0")/install.sh"
