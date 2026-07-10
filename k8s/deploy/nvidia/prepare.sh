#!/bin/bash
# prepare.sh — 下载 nvidia-device-plugin Helm chart 到本地
#
# 运行后：
#   /root/deploy/nvidia/nvidia-device-plugin/   nvidia-device-plugin chart
#
# 该路径即 install.sh 中 DEVICE_PLUGIN_CHART_DIR 的默认值。
set -e

DEVICE_PLUGIN_VERSION="${DEVICE_PLUGIN_VERSION:-0.19.3}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/nvidia}"
CHART_DIR="$DEPLOY_DIR/nvidia-device-plugin"

mkdir -p "$DEPLOY_DIR"

echo "=== Pull nvidia-device-plugin chart (${DEVICE_PLUGIN_VERSION}) ==="
if [ -f "$CHART_DIR/Chart.yaml" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $CHART_DIR）"
else
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin 2>/dev/null || true
  https_proxy=socks5h://127.0.0.1:1080 helm repo update nvdp 2>/dev/null
  helm pull nvdp/nvidia-device-plugin \
    --version "$DEVICE_PLUGIN_VERSION" \
    --untar --untardir "$DEPLOY_DIR"
  echo "  下载到 $CHART_DIR"
fi

echo ""
echo "=== 准备完成 ==="
echo "  nvidia-device-plugin chart : $CHART_DIR"
echo ""
echo "现在可运行 install.sh："
echo "  bash $(dirname "$0")/install.sh"
