#!/bin/bash
# install.sh — 在 K8s 集群上安装 NVIDIA Device Plugin
#
# 前置：
#   - 已运行 prepare.sh（chart 已就绪）
#   - 已运行 downlowd-image.sh（镜像已预拉到所有 GPU 节点）
#   - GPU 节点 containerd 已配置使用 nvidia-container-runtime
#
# 环境变量（可覆盖）：
#   DEVICE_PLUGIN_CHART_DIR   chart 目录（prepare.sh 下载）
set -e

DEVICE_PLUGIN_CHART_DIR="${DEVICE_PLUGIN_CHART_DIR:-/root/deploy/nvidia/nvidia-device-plugin}"

echo "=== Install nvidia-device-plugin ==="
if [ ! -f "$DEVICE_PLUGIN_CHART_DIR/Chart.yaml" ]; then
  echo "ERROR: $DEVICE_PLUGIN_CHART_DIR 不存在，请先运行 prepare.sh" >&2
  exit 1
fi

helm upgrade --install nvidia-device-plugin "$DEVICE_PLUGIN_CHART_DIR" \
  --namespace kube-system \
  --set compatWithCPUManager=false \
  --set failOnInitError=false \
  --set nvidiaDriverRoot=/ \
  --wait --timeout=120s

echo ""
echo "=== Verify ==="
kubectl get ds nvidia-device-plugin -n kube-system
echo ""
kubectl get nodes -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d['items']:
    name=n['metadata']['name']
    gpu=n['status'].get('allocatable',{}).get('nvidia.com/gpu','0')
    if int(gpu) > 0:
        print(f'  {name}: {gpu} GPU(s)')
"

echo ""
echo "Done."
