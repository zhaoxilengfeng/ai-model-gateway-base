#!/bin/bash
# install.sh — 安装全局基础设施（一次性）
#
# 职责：GIE CRDs + agentgateway CRDs + agentgateway controller + namespace + HF token
# 之后通过 install-pool.sh 为每个模型创建推理池
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
AGENTGATEWAY_VERSION="${AGENTGATEWAY_VERSION:-v1.3.1}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-precise-prefix-gateway}"

AGW_CHART_DIR="$DEPLOY_DIR/agentgateway/agentgateway"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"
AGW_CRD_DIR="$DEPLOY_DIR/agentgateway-crds"

for f in "$AGW_CHART_DIR/Chart.yaml" "$GIE_YAML"; do
  [ -f "$f" ] || { echo "ERROR: $f 不存在，请先运行 prepare.sh" >&2; exit 1; }
done

echo "=== 1. Install GIE CRDs ==="
kubectl apply --server-side -f "$GIE_YAML"

echo "=== 2. Install Agentgateway CRDs ==="
if [ -d "$AGW_CRD_DIR" ] && ls "$AGW_CRD_DIR"/*.yaml &>/dev/null; then
  kubectl apply --server-side -f "$AGW_CRD_DIR/"
else
  echo "  WARNING: $AGW_CRD_DIR 不存在，跳过"
fi

echo "=== 3. Install Agentgateway Controller ==="
helm upgrade --install agentgateway "$AGW_CHART_DIR" \
  --namespace agentgateway-system --create-namespace \
  --set inferenceExtension.enabled=true \
  --set image.pullPolicy=IfNotPresent \
  --set controller.image.pullPolicy=IfNotPresent \
  --skip-crds \
  --wait --timeout=180s

echo "=== 4. Create namespace ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 5. Create HF token secret ==="
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN:-dummy}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== 全局基础设施安装完成 ==="
echo "下一步：为每个模型运行 install-pool.sh，例如："
echo "  bash install-pool.sh --pool qwen25-7b"
echo "  bash install-pool.sh --pool glm4-9b"
kubectl get pods -n agentgateway-system
