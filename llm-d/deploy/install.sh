#!/bin/bash
# install.sh — 在 K8s 集群上安装 llm-d v0.8.1 基础组件（不含模型）
#
# 安装顺序：
#   1. Gateway API CRDs v1.2.1（兼容 K8s v1.27）
#   2. GIE CRDs（InferencePool / InferenceModel，api-approved annotation）
#   3. llm-d（model-service operator + Redis，via Helm）
#
# 前置：
#   - 已运行 prepare.sh（Gateway API yaml 和 llm-d chart 已就绪）
#   - 已运行 downlowd-image.sh（镜像已预拉到本地）
#   - kubectl 已配置好 kubeconfig
#
# 环境变量（均有默认值，可覆盖）：
#   GATEWAY_API_YAML   Gateway API CRD yaml 文件路径
#   LLM_D_CHART_DIR    llm-d Helm chart 目录
#   NAMESPACE          目标 namespace，默认 default
set -e

GATEWAY_API_YAML="${GATEWAY_API_YAML:-/root/deploy/llm-d/gateway-api/standard-install.yaml}"
LLM_D_CHART_DIR="${LLM_D_CHART_DIR:-/root/deploy/llm-d/llm-d-chart}"
NAMESPACE="${NAMESPACE:-default}"

echo "=== 1. Install Gateway API CRDs ==="
if [ ! -f "$GATEWAY_API_YAML" ]; then
  echo "ERROR: $GATEWAY_API_YAML 不存在，请先运行 prepare.sh" >&2
  exit 1
fi
kubectl apply --server-side -f "$GATEWAY_API_YAML"

echo "=== 2. Install GIE CRDs (InferencePool + InferenceModel) ==="
# 新版 group（inference.networking.k8s.io/v1）供 deploy-model.sh 使用
# 旧版 group（inference.networking.x-k8s.io/v1alpha2）供 llm-d model-service operator 使用
kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: inferencepools.inference.networking.k8s.io
  annotations:
    api-approved.kubernetes.io: "https://github.com/kubernetes-sigs/gateway-api-inference-extension"
spec:
  group: inference.networking.k8s.io
  names:
    kind: InferencePool
    plural: inferencepools
    shortNames: [infpool]
    singular: inferencepool
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec: {type: object, x-kubernetes-preserve-unknown-fields: true}
          status: {type: object, x-kubernetes-preserve-unknown-fields: true}
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: inferencemodels.inference.networking.k8s.io
  annotations:
    api-approved.kubernetes.io: "https://github.com/kubernetes-sigs/gateway-api-inference-extension"
spec:
  group: inference.networking.k8s.io
  names:
    kind: InferenceModel
    plural: inferencemodels
    shortNames: [infmodel]
    singular: inferencemodel
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec: {type: object, x-kubernetes-preserve-unknown-fields: true}
          status: {type: object, x-kubernetes-preserve-unknown-fields: true}
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: inferencepools.inference.networking.x-k8s.io
  annotations:
    api-approved.kubernetes.io: "https://github.com/kubernetes-sigs/gateway-api-inference-extension"
spec:
  group: inference.networking.x-k8s.io
  names:
    kind: InferencePool
    plural: inferencepools
    shortNames: [infpool]
    singular: inferencepool
  scope: Namespaced
  versions:
  - name: v1alpha2
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec: {type: object, x-kubernetes-preserve-unknown-fields: true}
          status: {type: object, x-kubernetes-preserve-unknown-fields: true}
    subresources:
      status: {}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: inferencemodels.inference.networking.x-k8s.io
  annotations:
    api-approved.kubernetes.io: "https://github.com/kubernetes-sigs/gateway-api-inference-extension"
spec:
  group: inference.networking.x-k8s.io
  names:
    kind: InferenceModel
    plural: inferencemodels
    shortNames: [infmodel]
    singular: inferencemodel
  scope: Namespaced
  versions:
  - name: v1alpha2
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec: {type: object, x-kubernetes-preserve-unknown-fields: true}
          status: {type: object, x-kubernetes-preserve-unknown-fields: true}
    subresources:
      status: {}
EOF

echo "=== 2b. Install ModelService CRD (from llm-d chart) ==="
kubectl apply -f "${LLM_D_CHART_DIR}/crds/"

echo "=== 3. Install llm-d (model-service operator + Redis) ==="
if [ ! -f "$LLM_D_CHART_DIR/Chart.yaml" ]; then
  echo "ERROR: $LLM_D_CHART_DIR 不存在，请先运行 prepare.sh" >&2
  exit 1
fi
helm upgrade --install llm-d "$LLM_D_CHART_DIR" \
  --namespace llm-d --create-namespace \
  --set sampleApplication.enabled=false \
  --set gateway.enabled=false \
  --set ingress.enabled=false \
  --set modelservice.metrics.enabled=false \
  --set modelservice.epp.metrics.enabled=false \
  --wait --timeout=120s

echo ""
echo "=== Verify ==="
kubectl get pods -n llm-d
kubectl get crd | grep -E "inferencepools|inferencemodels"

echo ""
echo "Done. 现在可运行 deploy-model.sh 部署模型："
echo "  bash $(dirname "$0")/deploy-model.sh <model-name> <model-path> [replicas] [node]"
echo ""
echo "部署完成后可运行性能基准测试："
echo "  cd /root/ai-model-gateway-base/gateway-benchmark"
echo "  ./run_llmd.sh --workload sanity.yaml --experiment sanity.yaml"
