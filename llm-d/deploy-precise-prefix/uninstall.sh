#!/bin/bash
# uninstall.sh — 清理 precise-prefix-cache-routing 所有资源
set -e

GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"

echo "=== 1. Helm uninstall router ==="
helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "  no helm release: ${GUIDE_NAME}"

echo "=== 2. Delete render (tokenizer) Service ==="
kubectl delete -n "${NAMESPACE}" -k "${REPO_ROOT}/guides/${GUIDE_NAME}/render/" 2>/dev/null || echo "  no render resources"

echo "=== 3. Delete model deployments ==="
kubectl delete deployment,svc -n "${NAMESPACE}" -l "llm-d.ai/guide=${GUIDE_NAME}" 2>/dev/null || echo "  no model resources"

echo "=== 4. Delete namespace ==="
kubectl delete namespace "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  no namespace: ${NAMESPACE}"

echo ""
echo "Done."
