#!/bin/bash
# install.sh — 安装 precise-prefix-cache-routing（精准前缀哈希路由）
#
# 路由模式：Standalone（EPP 内置 Envoy sidecar），不依赖外部 Gateway
# 核心机制：vLLM 通过 ZMQ :5556 发布 KV 块事件 → EPP 订阅并构建哈希索引
#           → 请求到来时按前缀哈希精准命中已缓存块最多的 pod
set -e

GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy/llm-d-precise-prefix}"

ROUTER_CHART_DIR="$DEPLOY_DIR/llm-d-router-standalone"
GIE_YAML="$DEPLOY_DIR/gie-${GAIE_VERSION}.yaml"

[ -f "$ROUTER_CHART_DIR/Chart.yaml" ] || { echo "ERROR: 请先运行 prepare.sh" >&2; exit 1; }
[ -f "$GIE_YAML" ]                    || { echo "ERROR: 请先运行 prepare.sh" >&2; exit 1; }

echo "=== 1. Install GIE CRDs ==="
kubectl apply --server-side -f "$GIE_YAML"

echo "=== 2. Create namespace ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 3. Create HF token secret ==="
kubectl create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN:-dummy}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== 4. Deploy render (tokenizer) Service ==="
# render service 用 CPU-only vLLM 做 tokenize，EPP token-producer 通过 HTTP 调用
kubectl apply -n "${NAMESPACE}" -k "${REPO_ROOT}/guides/${GUIDE_NAME}/render/"

echo "=== 5. Install llm-d-router-standalone (EPP + Envoy sidecar) ==="
helm upgrade --install "${GUIDE_NAME}" "$ROUTER_CHART_DIR" \
  -f "${REPO_ROOT}/guides/recipes/router/base.values.yaml" \
  -f "${REPO_ROOT}/guides/${GUIDE_NAME}/router/${GUIDE_NAME}.values.yaml" \
  -n "${NAMESPACE}" \
  --wait --timeout=180s

echo ""
echo "=== Verify ==="
kubectl get pods -n "${NAMESPACE}"
kubectl get inferencepool -n "${NAMESPACE}"

EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<pending>")
echo ""
echo "Done. 下一步运行 deploy-model.sh 部署模型。"
echo "EPP ClusterIP: http://${EPP_IP}"
