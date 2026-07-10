#!/bin/bash
# install.sh — 安装 llm-d standalone 模式基础组件
#
# 前置：已运行 prepare.sh 和 downlowd-image.sh
#
# 环境变量（可覆盖）：
#   GUIDE_NAME    Helm release 名，默认 quickstart
#   NAMESPACE     K8s namespace，默认 llm-d-standalone
#   GAIE_VERSION  GIE CRD 版本，默认 v1.5.0
#   REPO_ROOT     llm-d 仓库根目录，默认 /root/llm-d
set -e

GUIDE_NAME="${GUIDE_NAME:-quickstart}"
NAMESPACE="${NAMESPACE:-llm-d-standalone}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-standalone}"
CHART_DIR="$DEPLOY_DIR/llm-d-router-standalone"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

if [ ! -f "$CHART_DIR/Chart.yaml" ] || [ ! -f "$GIE_YAML" ]; then
  echo "ERROR: 请先运行 prepare.sh" >&2; exit 1
fi

echo "=== 1. Install GIE CRDs ==="
kubectl apply --server-side -f "$GIE_YAML"

echo "=== 2. Create namespace ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 3. Create HF token secret ==="
HF_TOKEN="${HF_TOKEN:-dummy}"
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== 4. Install llm-d-router-standalone ==="
helm upgrade --install "${GUIDE_NAME}" "$CHART_DIR" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/optimized-baseline/router/optimized-baseline.values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout=120s

echo ""
echo "=== Verify ==="
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "Done. 下一步运行 deploy-model.sh 部署模型。"
