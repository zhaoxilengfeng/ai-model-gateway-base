#!/bin/bash
# test-llmd.sh — 验证 precise-prefix-cache-routing gateway 模式服务是否可用

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix-gw}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
MODEL="${MODEL:-qwen25-7b-instruct}"
GW_SVC="${GW_SVC:-llm-d-inference-gateway}"

echo "=== precise-prefix-cache-routing gateway 健康检查 ==="

# 1. Pod 状态
echo ""
echo "[1] Pod 状态 (${NAMESPACE}):"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
echo "[1b] Agentgateway controller:"
kubectl get pods -n agentgateway-system -o wide

# 2. Gateway / HTTPRoute / InferencePool 状态
echo ""
echo "[2] Gateway / HTTPRoute / InferencePool:"
kubectl get gateway,httproute,inferencepool -n "${NAMESPACE}"

# 3. ZMQ 连接检查
echo ""
echo "[3] ZMQ 连接检查（EPP 是否订阅了 vLLM KV 事件 socket）:"
EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null | grep "Connected subscriber socket" | tail -5

# 4. vLLM /health 直连
MODEL_IP=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
if [ -n "${MODEL_IP}" ]; then
  echo ""
  echo "[4] vLLM /health (pod ${MODEL_IP}:8000):"
  curl -sf --max-time 5 "http://${MODEL_IP}:8000/health" && echo " OK" || echo " FAIL"
fi

# 5. 获取 NodePort 并发送推理请求
NODE_PORT=$(kubectl get svc "${GW_SVC}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

if [ -z "${NODE_PORT}" ]; then
  echo ""
  echo "ERROR: 找不到 svc/${GW_SVC} 的 NodePort"
  exit 1
fi

echo ""
echo "[5] 推理测试 via NodePort (http://${NODE_IP}:${NODE_PORT}):"
RESP=$(curl -sf --max-time 30 "http://${NODE_IP}:${NODE_PORT}/v1/chat/completions" \
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
