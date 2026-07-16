#!/bin/bash
# install-inferencemodel-crd.sh — 安装 InferenceModel CRD
#
# InferenceModel 是 GIE（Gateway API Inference Extension）规范资源，
# 固安集群当前仅安装了 InferencePool CRD，需单独安装 InferenceModel CRD。
#
# 用法:
#   bash install-inferencemodel-crd.sh
#   GAIE_VERSION=v1.5.0 bash install-inferencemodel-crd.sh
set -e

GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
MANIFEST_URL="https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"

echo "=== 安装 InferenceModel CRD ==="
echo "  GIE 版本: ${GAIE_VERSION}"
echo "  Manifest: ${MANIFEST_URL}"
echo ""

# 检查是否已安装
if kubectl get crd inferencemodels.inference.networking.k8s.io &>/dev/null; then
  echo "  InferenceModel CRD 已存在，跳过安装"
  kubectl get crd inferencemodels.inference.networking.k8s.io
  exit 0
fi

echo "  正在下载并安装..."
ALL_PROXY="${ALL_PROXY:-socks5h://127.0.0.1:1080}" \
  kubectl apply -f "${MANIFEST_URL}" 2>/dev/null || \
  kubectl apply -f "${MANIFEST_URL}"

echo ""
echo "=== 安装结果 ==="
kubectl get crd | grep inference
