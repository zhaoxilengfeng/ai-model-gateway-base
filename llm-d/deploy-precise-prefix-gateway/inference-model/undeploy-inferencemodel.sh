#!/bin/bash
# undeploy-inferencemodel.sh — 删除指定模型的 InferenceModel 资源
#
# 用法:
#   bash undeploy-inferencemodel.sh <model-name>
#   bash undeploy-inferencemodel.sh qwen25-7b-instruct
set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
MODEL_NAME="${1:-}"

if [[ -z "$MODEL_NAME" ]]; then
  echo "用法: bash undeploy-inferencemodel.sh <model-name>"
  echo ""
  echo "当前 namespace ${NAMESPACE} 中的 InferenceModel:"
  kubectl get inferencemodel -n "${NAMESPACE}" 2>/dev/null || echo "  （InferenceModel CRD 未安装）"
  exit 1
fi

if kubectl delete inferencemodel "${MODEL_NAME}" -n "${NAMESPACE}" 2>/dev/null; then
  echo "✓ InferenceModel '${MODEL_NAME}' 已删除"
else
  echo "跳过: InferenceModel '${MODEL_NAME}' 不存在"
fi

echo ""
echo "=== 当前 ${NAMESPACE} 中的 InferenceModel ==="
kubectl get inferencemodel -n "${NAMESPACE}" 2>/dev/null || true
