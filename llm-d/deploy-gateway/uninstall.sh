#!/bin/bash
# uninstall.sh — 卸载 llm-d gateway 模式
set -e

GUIDE_NAME="${GUIDE_NAME:-quickstart}"
NAMESPACE="${NAMESPACE:-llm-d-gateway}"
MODEL_NAME="${MODEL_NAME:-}"

if [ -n "$MODEL_NAME" ]; then
  echo "=== 仅清理模型: $MODEL_NAME ==="
  kubectl delete deployment "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete service "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found
  echo "Done."
  exit 0
fi

echo "=== 全量卸载 llm-d gateway ==="

echo "=== 1. Helm uninstall router ==="
helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "  no helm release: ${GUIDE_NAME}"

echo "=== 2. Delete namespace ==="
kubectl delete namespace "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  no namespace: ${NAMESPACE}"

echo "=== 3. Uninstall Agentgateway ==="
helm uninstall agentgateway -n agentgateway-system 2>/dev/null || echo "  no helm release: agentgateway"
kubectl delete namespace agentgateway-system --timeout=60s 2>/dev/null || echo "  no namespace: agentgateway-system"

echo "=== 4. Delete GIE CRDs ==="
kubectl delete crd inferencepools.inference.networking.k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd inferencemodels.inference.networking.k8s.io --ignore-not-found 2>/dev/null || true

echo ""
echo "Done."
