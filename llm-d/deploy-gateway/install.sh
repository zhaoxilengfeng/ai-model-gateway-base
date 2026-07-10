#!/bin/bash
# install.sh — 安装 llm-d gateway 模式（Agentgateway + llm-d-router-gateway）
#
# 前置：已运行 prepare.sh 和 downlowd-image.sh
set -e

GUIDE_NAME="${GUIDE_NAME:-quickstart}"
NAMESPACE="${NAMESPACE:-llm-d-gateway}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
AGENTGATEWAY_VERSION="${AGENTGATEWAY_VERSION:-v1.3.1}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-gateway}"

ROUTER_CHART_DIR="$DEPLOY_DIR/llm-d-router-gateway"
AGW_CHART_DIR="$DEPLOY_DIR/agentgateway/agentgateway"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

AGW_CRD_DIR="$DEPLOY_DIR/agentgateway-crds"

for f in "$ROUTER_CHART_DIR/Chart.yaml" "$AGW_CHART_DIR/Chart.yaml" "$GIE_YAML"; do
  [ -f "$f" ] || { echo "ERROR: $f 不存在，请先运行 prepare.sh" >&2; exit 1; }
done

echo "=== 1. Install GIE CRDs ==="
kubectl apply --server-side -f "$GIE_YAML"

echo "=== 2. Install Agentgateway CRDs ==="
if [ -d "$AGW_CRD_DIR" ] && ls "$AGW_CRD_DIR"/*.yaml &>/dev/null; then
  kubectl apply --server-side -f "$AGW_CRD_DIR/"
else
  echo "  WARNING: $AGW_CRD_DIR 不存在，跳过（agentgateway controller 可能无法启动）"
fi

echo "=== 3. Install Agentgateway ==="

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

echo "=== 6. Deploy Gateway resource ==="
kubectl apply -k "${REPO_ROOT}/guides/recipes/gateway/agentgateway" -n "${NAMESPACE}"
echo "  等待 Gateway programmed..."
kubectl wait gateway/llm-d-inference-gateway -n "${NAMESPACE}" \
  --for=jsonpath='{.status.conditions[?(@.type=="Programmed")].status}=True' \
  --timeout=60s 2>/dev/null || kubectl get gateway llm-d-inference-gateway -n "${NAMESPACE}"

echo "=== 7. Install llm-d-router-gateway ==="
helm upgrade --install "${GUIDE_NAME}" "$ROUTER_CHART_DIR" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/optimized-baseline/router/optimized-baseline.values.yaml" \
  -n "${NAMESPACE}" \
  --set provider.name=agentgateway \
  --set httpRoute.create=true \
  --set httpRoute.inferenceGatewayName=llm-d-inference-gateway \
  --wait --timeout=120s

echo ""
echo "=== Verify ==="
kubectl get pods -n agentgateway-system
kubectl get pods -n "${NAMESPACE}"
kubectl get gateway,httproute -n "${NAMESPACE}"
echo ""
NODE_PORT=$(kubectl get svc llm-d-inference-gateway -n "${NAMESPACE}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "<pending>")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Done. 下一步运行 deploy-model.sh 部署模型。"
echo ""
echo "访问地址（NodePort）: http://${NODE_IP}:${NODE_PORT}"
