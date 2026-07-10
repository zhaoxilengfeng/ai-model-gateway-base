#!/bin/bash
# uninstall.sh — 清理 llm-d 全部组件
#
# 支持两种模式：
#   全量清理（默认）：  bash uninstall.sh
#   仅清理某个模型：    MODEL_NAME=<name> bash uninstall.sh
set -e

NAMESPACE="${NAMESPACE:-default}"
MODEL_NAME="${MODEL_NAME:-}"

if [ -n "$MODEL_NAME" ]; then
  echo "=== 仅清理模型: $MODEL_NAME ==="

  echo "--- 1. Delete vLLM Deployment + Service + PDB ---"
  kubectl delete deployment "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete service "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete pdb "${MODEL_NAME}-pdb" -n "${NAMESPACE}" --ignore-not-found

  echo "--- 2. Delete EPP Deployment + Service + PDB + ConfigMap ---"
  kubectl delete deployment "${MODEL_NAME}-endpoint-picker" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete service "${MODEL_NAME}-endpoint-picker" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete pdb "${MODEL_NAME}-endpoint-picker-pdb" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete configmap "${MODEL_NAME}-epp-config" -n "${NAMESPACE}" --ignore-not-found

  echo "--- 3. Delete InferencePool + HTTPRoute ---"
  kubectl delete inferencepools.inference.networking.k8s.io "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete inferencepools.inference.networking.x-k8s.io "${MODEL_NAME}" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete httproute "${MODEL_NAME}-route" -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  echo ""
  echo "模型 ${MODEL_NAME} 已清理。Gateway 资源保留（其他模型仍在使用）。"
  echo "如需同时删除 Gateway：kubectl delete gateway inference-gateway -n ${NAMESPACE}"
  exit 0
fi

echo "=== 全量卸载 llm-d ==="

echo "=== 1. Delete all model Deployments / Services / PDBs / ConfigMaps ==="
for resource in deployment service pdb configmap; do
  names=$(kubectl get ${resource} -n "${NAMESPACE}" -l app.kubernetes.io/part-of=llm-d \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  for name in ${names}; do
    kubectl delete ${resource} "${name}" -n "${NAMESPACE}" --ignore-not-found
  done
done

echo "=== 2. Delete InferencePools + HTTPRoutes ==="
kubectl delete inferencepools.inference.networking.k8s.io \
  -n "${NAMESPACE}" --all --ignore-not-found 2>/dev/null || true
kubectl delete inferencepools.inference.networking.x-k8s.io \
  -n "${NAMESPACE}" --all --ignore-not-found 2>/dev/null || true
kubectl delete httproute \
  -n "${NAMESPACE}" -l app.kubernetes.io/part-of=llm-d --ignore-not-found 2>/dev/null || true

echo "=== 3. Delete Gateways ==="
kubectl delete gateway \
  -n "${NAMESPACE}" -l app.kubernetes.io/part-of=llm-d --ignore-not-found 2>/dev/null || true

echo "=== 4. Delete EPP RBAC ==="
kubectl delete clusterrolebinding llm-d-epp --ignore-not-found
kubectl delete clusterrole llm-d-epp --ignore-not-found
kubectl delete serviceaccount llm-d-epp -n "${NAMESPACE}" --ignore-not-found

echo "=== 5. Uninstall llm-d Helm release (model-service + Redis) ==="
helm uninstall llm-d -n llm-d 2>/dev/null || echo "  no helm release: llm-d"
kubectl delete namespace llm-d --timeout=60s 2>/dev/null || echo "  no namespace: llm-d"
kubectl delete crd modelservices.llm-d.ai --ignore-not-found 2>/dev/null || true

echo "=== 6. Delete GIE CRDs ==="
kubectl delete crd inferencepools.inference.networking.k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd inferencemodels.inference.networking.k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd inferencepools.inference.networking.x-k8s.io --ignore-not-found 2>/dev/null || true
kubectl delete crd inferencemodels.inference.networking.x-k8s.io --ignore-not-found 2>/dev/null || true

echo "=== 7. Delete Gateway API CRDs ==="
kubectl get crd 2>/dev/null | grep "gateway.networking.k8s.io" | awk '{print $1}' | \
  xargs -r kubectl delete crd --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Verify ==="
kubectl get ns | grep -E "llm-d" || echo "namespaces cleaned"
kubectl get crd | grep -E "inference|gateway.networking" || echo "CRDs cleaned"

echo "Done."
