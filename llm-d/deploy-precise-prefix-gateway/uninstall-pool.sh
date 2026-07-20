#!/bin/bash
# uninstall-pool.sh — 清理单个推理池的所有资源
#
# 用法：
#   bash uninstall-pool.sh --pool qwen25-7b
#   bash uninstall-pool.sh --guide-name my-pool --namespace llm-d-my-ns

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POOL=""
GUIDE_NAME=""
NAMESPACE="llm-d-precise-prefix-gw"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)        POOL="$2";       shift 2 ;;
    --guide-name)  GUIDE_NAME="$2"; shift 2 ;;
    --namespace)   NAMESPACE="$2";  shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "$POOL" ]]; then
  POOL_ENV="$SCRIPT_DIR/pools/$POOL/pool.env"
  [[ -f "$POOL_ENV" ]] && source "$POOL_ENV"
fi

: "${GUIDE_NAME:?必须设置 GUIDE_NAME（--guide-name 或 --pool）}"

echo "=== 清理推理池: $GUIDE_NAME (namespace: $NAMESPACE) ==="

echo "1. Helm uninstall EPP + HTTPRoute + InferencePool"
helm uninstall "${GUIDE_NAME}" -n "${NAMESPACE}" 2>/dev/null || echo "  no helm release: ${GUIDE_NAME}"

echo "2. Delete model pods (Deployment + Service)"
kubectl delete deployment,svc -n "${NAMESPACE}" \
  -l "llm-d.ai/guide=${GUIDE_NAME}" 2>/dev/null || echo "  no model resources"

echo "3. Delete render Service"
kubectl delete deployment,svc -n "${NAMESPACE}" \
  -l "app.kubernetes.io/part-of=${GUIDE_NAME}" 2>/dev/null || echo "  no render resources"

echo "4. Delete Gateway"
kubectl delete gateway "${GUIDE_NAME}-gateway" -n "${NAMESPACE}" 2>/dev/null || echo "  no gateway: ${GUIDE_NAME}-gateway"

echo ""
echo "=== 推理池 ${GUIDE_NAME} 已清理 ==="
kubectl get pods -n "${NAMESPACE}" 2>/dev/null | grep -v "^NAME" || echo "  namespace 已无 pod"
