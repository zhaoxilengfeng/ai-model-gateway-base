#!/bin/bash
# uninstall.sh — 清理所有推理池 + 全局基础设施

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
REPO_ROOT="${REPO_ROOT:-/root/llm-d}"

echo "=== 清理所有推理池 ==="
for pool_dir in "$SCRIPT_DIR/pools/"/*/; do
  pool=$(basename "$pool_dir")
  echo "清理池: $pool"
  bash "$SCRIPT_DIR/uninstall-pool.sh" --pool "$pool" --namespace "$NAMESPACE" 2>/dev/null || true
done

echo "=== 清理全局基础设施 ==="
helm uninstall agentgateway -n agentgateway-system 2>/dev/null || echo "  no agentgateway"

kubectl delete namespace "$NAMESPACE" --timeout=60s 2>/dev/null || echo "  no namespace: $NAMESPACE"
kubectl delete namespace agentgateway-system --timeout=60s 2>/dev/null || echo "  no namespace: agentgateway-system"

echo "Done."
