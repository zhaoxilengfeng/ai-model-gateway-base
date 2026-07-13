#!/bin/bash
# test-llmd.sh — 验证 precise-prefix-cache-routing 服务可用性

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
MODEL="${MODEL:-qwen25-7b-instruct}"

echo "=== precise-prefix-cache-routing 健康检查 ==="

# 1. Pod 状态
echo ""
echo "[1] Pod 状态:"
kubectl get pods -n "${NAMESPACE}" -o wide

# 2. EPP 地址
EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "${EPP_IP}" ]; then
  echo "ERROR: 找不到 svc/${GUIDE_NAME}-epp"
  exit 1
fi
echo ""
echo "[2] EPP ClusterIP: http://${EPP_IP}"

# 3. InferencePool 状态
echo ""
echo "[3] InferencePool:"
kubectl get inferencepool -n "${NAMESPACE}"

# 4. vLLM /health 直连
MODEL_IP=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
if [ -n "${MODEL_IP}" ]; then
  echo ""
  echo "[4] vLLM /health (pod ${MODEL_IP}:8000):"
  curl -sf --max-time 5 "http://${MODEL_IP}:8000/health" && echo " OK" || echo " FAIL"

  # 检查 ZMQ kv-events 端口是否监听
  echo ""
  echo "[4b] ZMQ kv-events port :5556 (pod ${MODEL_IP}):"
  kubectl exec -n "${NAMESPACE}" \
    $(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" -o jsonpath='{.items[0].metadata.name}') \
    -- sh -c 'ss -tnlp 2>/dev/null | grep 5556 && echo " LISTENING" || echo " NOT FOUND"' 2>/dev/null \
    || echo "  (exec 不可用，跳过)"
fi

# 5. 推理测试（via EPP）
echo ""
echo "[5] 推理测试 (via EPP → ${MODEL}):"
RESP=$(curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":10}" 2>&1)

if echo "${RESP}" | grep -q '"finish_reason"'; then
  CONTENT=$(echo "${RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null)
  echo " OK — 模型回复: ${CONTENT}"
else
  echo " FAIL — 响应: ${RESP}"
  exit 1
fi

echo ""
echo "=== 全部检查通过 ==="
echo ""
echo "下一步：运行性能基准测试"
echo "  cd /root/ai-model-gateway-base/gateway-benchmark"
echo "  ./run_llmd.sh --workload sanity.yaml --experiment sanity.yaml"
