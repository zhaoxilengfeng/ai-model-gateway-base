#!/bin/bash
# undeploy-model.sh — 销毁指定模型的 Deployment 和 Service
#
# 用法:
#   bash undeploy-model.sh <model-name>
#   bash undeploy-model.sh qwen25-7b-instruct
#   bash undeploy-model.sh glm-5-2-fp8
#
# 默认 Namespace: llm-d-precise-prefix-gw
set -euo pipefail

MODEL_NAME="${1:-}"
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"

if [[ -z "$MODEL_NAME" ]]; then
  echo "用法: bash undeploy-model.sh <model-name>"
  echo ""
  echo "当前 namespace ${NAMESPACE} 中的模型 deployment:"
  kubectl get deployment -n "${NAMESPACE}" \
    -l "llm-d.ai/guide" --no-headers 2>/dev/null | awk '{print "  " $1}' || \
  kubectl get deployment -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    grep -v 'epp\|render\|gateway' | awk '{print "  " $1}' || \
  echo "  （无）"
  exit 1
fi

echo "=== 销毁模型: ${MODEL_NAME} (namespace: ${NAMESPACE}) ==="

# 删除 Deployment
if kubectl get deployment "${MODEL_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  kubectl delete deployment "${MODEL_NAME}" -n "${NAMESPACE}"
  echo "  ✓ Deployment ${MODEL_NAME} 已删除"
else
  echo "  跳过: Deployment ${MODEL_NAME} 不存在"
fi

# 删除 Service
if kubectl get service "${MODEL_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  kubectl delete service "${MODEL_NAME}" -n "${NAMESPACE}"
  echo "  ✓ Service ${MODEL_NAME} 已删除"
else
  echo "  跳过: Service ${MODEL_NAME} 不存在"
fi

# 等待 pod 清理完成
# GLM sglang 用 app= 标签，vLLM/qwen-sglang 用 llm-d.ai/model= 标签，两个都等
echo "  等待 pod 退出..."
kubectl wait --for=delete pod \
  -l "llm-d.ai/model=${MODEL_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=60s 2>/dev/null || true
kubectl wait --for=delete pod \
  -l "app=${MODEL_NAME}" \
  -n "${NAMESPACE}" \
  --timeout=60s 2>/dev/null || true

echo ""
echo "=== 当前 ${NAMESPACE} 中剩余 pod ==="
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print "  " $0}'
echo ""
echo "=== GPU 释放情况 ==="
NODE_IP=$(kubectl get node h200-12-3 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "11.194.12.3")
if ssh -o ConnectTimeout=5 root@${NODE_IP} 'nvidia-smi --query-gpu=index,memory.used --format=csv,noheader' 2>/dev/null; then
  :
else
  echo "  (无法连接到 ${NODE_IP}，请手动确认 GPU 释放)"
fi
