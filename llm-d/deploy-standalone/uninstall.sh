#!/bin/bash
# uninstall.sh — 卸载 llm-d standalone 模式
#
# 支持两种模式：
#   全量清理（默认）：  bash uninstall.sh
#   仅清理某个模型：    MODEL_NAME=<name> bash uninstall.sh
set -e

GUIDE_NAME="${GUIDE_NAME:-quickstart}"
NAMESPACE="${NAMESPACE:-llm-d-standalone}"
MODEL_NAME="${MODEL_NAME:-}"

if [ -n "$MODEL_NAME" ]; then
  echo "=== 仅清理模型: $MODEL_NAME ==="
  kubectl delete deployment "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete service "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found
  echo "Done."
  exit 0
fi

echo "=== 全量卸载 llm-d standalone ==="

echo "=== 1. Helm uninstall router (llm-d-standalone) ==="
helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "  no helm release: ${GUIDE_NAME}"

echo "=== 2. Delete namespace llm-d-standalone ==="
kubectl delete namespace "${NAMESPACE}" --timeout=60s 2>/dev/null || echo "  no namespace: ${NAMESPACE}"

echo "=== 3. Helm uninstall llm-d (modelservice + redis) ==="
helm uninstall llm-d -n llm-d 2>/dev/null || echo "  no helm release: llm-d"

echo "=== 4. Delete namespace llm-d ==="
kubectl delete namespace llm-d --timeout=60s 2>/dev/null || echo "  no namespace: llm-d"

echo "=== 5. Delete GIE CRDs ==="
kubectl delete crd inferencepools.inference.networking.k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd inferencemodels.inference.networking.k8s.io --ignore-not-found 2>/dev/null || true

echo ""
echo "Done."
