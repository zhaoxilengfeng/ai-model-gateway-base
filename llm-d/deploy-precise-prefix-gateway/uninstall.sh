#!/bin/bash
# uninstall.sh — 清理 precise-prefix-cache-routing gateway 模式所有资源
set -e

GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"

echo "=== 1. Helm uninstall router ==="
helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "  no helm release: ${GUIDE_NAME}"

echo "=== 2. Helm uninstall agentgateway ==="
helm uninstall agentgateway -n agentgateway-system 2>/dev/null || echo "  no helm release: agentgateway"

echo "=== 3. Delete render (tokenizer) Service ==="
kubectl delete deployment,svc -n "${NAMESPACE}" \
  -l "app.kubernetes.io/part-of=${GUIDE_NAME}" 2>/dev/null || echo "  no render resources"

echo "=== 4. Delete Gateway resource ==="
kubectl delete -k "${REPO_ROOT}/guides/recipes/gateway/agentgateway" -n "${NAMESPACE}" 2>/dev/null || echo "  no gateway resources"

echo "=== 5. Delete model deployments ==="
kubectl delete deployment,svc -n "${NAMESPACE}" \
  -l "llm-d.ai/guide=${GUIDE_NAME}" 2>/dev/null || echo "  no model resources"

echo "=== 6. Delete namespace ==="
kubectl delete namespace "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  no namespace: ${NAMESPACE}"

echo "=== 7. Delete agentgateway-system namespace ==="
kubectl delete namespace agentgateway-system --timeout=60s 2>/dev/null || echo "  no namespace: agentgateway-system"

echo ""
echo "Done."
