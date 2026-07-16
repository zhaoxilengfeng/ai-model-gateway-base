#!/bin/bash
# deploy-inferencemodel.sh — 为指定模型创建 InferenceModel 资源
#
# InferenceModel 的作用：
#   1. 将请求 "model" 字段与 InferencePool 内的特定 Pod 绑定，实现模型隔离路由
#   2. 声明 SLO 优先级（criticality），在 Pool 繁忙时 EPP 按优先级决定丢弃哪些请求
#
# 用法:
#   bash deploy-inferencemodel.sh <model-name> [criticality]
#   bash deploy-inferencemodel.sh qwen25-7b-instruct
#   bash deploy-inferencemodel.sh glm-5-2-fp8 Standard
#   bash deploy-inferencemodel.sh my-model Sheddable
#
# criticality 等级:
#   Critical   — 最高优先级，资源紧张时最后被丢弃（生产核心服务）
#   Standard   — 默认等级，正常调度（默认值）
#   Sheddable  — 最低优先级，Pool 繁忙时 EPP 主动返回 429（离线批处理）
set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
POOL_NAME="${POOL_NAME:-precise-prefix-cache-routing}"
MODEL_NAME="${1:-}"
CRITICALITY="${2:-Standard}"

if [[ -z "$MODEL_NAME" ]]; then
  echo "用法: bash deploy-inferencemodel.sh <model-name> [criticality]"
  echo ""
  echo "criticality 可选值: Critical | Standard | Sheddable（默认 Standard）"
  echo ""
  echo "当前 namespace ${NAMESPACE} 中的 InferenceModel:"
  kubectl get inferencemodel -n "${NAMESPACE}" 2>/dev/null || echo "  （InferenceModel CRD 未安装，请先执行 install-inferencemodel-crd.sh）"
  exit 1
fi

# 检查 CRD 是否安装
if ! kubectl get crd inferencemodels.inference.networking.k8s.io &>/dev/null; then
  echo "错误: InferenceModel CRD 未安装"
  echo "请先执行: bash inference-model/install-inferencemodel-crd.sh"
  exit 1
fi

# 检查 InferencePool 是否存在
if ! kubectl get inferencepool "${POOL_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "错误: InferencePool '${POOL_NAME}' 在 namespace '${NAMESPACE}' 中不存在"
  exit 1
fi

echo "=== 创建 InferenceModel ==="
echo "  模型名:       ${MODEL_NAME}"
echo "  Pool:         ${POOL_NAME}"
echo "  Namespace:    ${NAMESPACE}"
echo "  Criticality:  ${CRITICALITY}"
echo ""

kubectl apply -n "${NAMESPACE}" -f - <<YAML
apiVersion: inference.networking.k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
  labels:
    llm-d.ai/model: ${MODEL_NAME}
spec:
  modelName: ${MODEL_NAME}
  poolRef:
    name: ${POOL_NAME}
  criticality: ${CRITICALITY}
YAML

echo ""
echo "=== 当前 ${NAMESPACE} 中的 InferenceModel ==="
kubectl get inferencemodel -n "${NAMESPACE}" 2>/dev/null
