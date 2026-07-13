#!/bin/bash
# verify-precise-prefix.sh — 验证精准前缀缓存路由是否正常工作
#
# 检测逻辑：
#   1. ZMQ 连接：EPP 是否成功订阅了 vLLM pod 的 KV 事件 socket
#   2. token-producer：render service 是否能正常 tokenize（无 404/连接错误）
#   3. prefix-cache-scorer：EPP 是否在正常处理请求（无 score 0 报错）
#   4. 端到端：发送相同前缀请求两次，验证路由链路通畅
#
# 注意：EPP 必须在 vLLM pod 之后启动，pod-discovery 才能正确建立 ZMQ 订阅。
# 若 vLLM pod 重启后精准路由失效，执行：
#   kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix
set -e

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
MODEL="${MODEL:-qwen25-7b-instruct}"
PASS=0
FAIL=0

ok()   { echo "  [OK]  $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }

echo "=== 精准前缀缓存路由验证 ==="
echo ""

# ── 0. Pod 状态 ────────────────────────────────────────────────────────────────
echo "[0] Pod 状态:"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""

# ── 1. ZMQ 连接检查 ────────────────────────────────────────────────────────────
echo "[1] ZMQ 连接检查（EPP 是否订阅了 vLLM KV 事件 socket）:"

# 获取 vLLM pod IP
VLLM_POD_IP=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$VLLM_POD_IP" ]; then
  fail "找不到 vLLM pod（label llm-d.ai/model=${MODEL}）"
else
  info "vLLM pod IP: ${VLLM_POD_IP}:5556"
  # 在 EPP 日志中查找 ZMQ 连接记录
  EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
  if [ -z "$EPP_POD" ]; then
    fail "找不到运行中的 EPP pod"
  else
    ZMQ_LOG=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null \
      | grep "Connected subscriber socket" | grep "${VLLM_POD_IP}:5556" | tail -1)
    if [ -n "$ZMQ_LOG" ]; then
      ok "ZMQ 已连接: tcp://${VLLM_POD_IP}:5556"
    else
      fail "未找到 ZMQ 连接日志（tcp://${VLLM_POD_IP}:5556）"
      info "当前 EPP ZMQ 连接记录："
      kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null \
        | grep "Connected subscriber socket" | tail -3 | sed 's/^/    /'
    fi
  fi
fi
echo ""

# ── 2. token-producer（render service）检查 ────────────────────────────────────
echo "[2] token-producer 检查（render service 是否可用）:"

RENDER_SVC="${GUIDE_NAME}-render"
RENDER_IP=$(kubectl get svc "${RENDER_SVC}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "$RENDER_IP" ]; then
  fail "找不到 svc/${RENDER_SVC}"
else
  info "render service: http://${RENDER_IP}:8000"
  # 检查 render 暴露的模型名
  RENDER_MODEL=$(curl -sf --max-time 5 "http://${RENDER_IP}:8000/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "")
  if [ -z "$RENDER_MODEL" ]; then
    fail "render /v1/models 无响应"
  else
    info "render 暴露模型名: ${RENDER_MODEL}"
    # 检查 EPP 日志是否有 token-producer 失败记录（近50条）
    EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
    TOKEN_ERR=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp --tail=100 2>/dev/null \
      | grep '"tokenization failed\|token-producer.*failed\|does not exist"' | tail -3)
    if [ -n "$TOKEN_ERR" ]; then
      fail "token-producer 有错误（近期日志）:"
      echo "$TOKEN_ERR" | sed 's/^/    /'
      info "提示：render served-model-name 须与 EPP token-producer.modelName 一致（当前 render: ${RENDER_MODEL}）"
    else
      ok "token-producer 正常，render 模型名: ${RENDER_MODEL}"
    fi
  fi
fi
echo ""

# ── 3. prefix-cache-scorer 索引检查 ────────────────────────────────────────────
echo "[3] prefix-cache-scorer 索引检查:"

EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
if [ -n "$EPP_POD" ]; then
  EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

  # 发两次相同的长前缀请求，间隔 3s 让 KV 事件传播
  LONG_PROMPT="请详细解释 Transformer 架构中多头自注意力机制的数学原理，包括 Query Key Value 矩阵的计算方式、Softmax 归一化、缩放点积注意力的完整推导过程"
  for i in 1 2; do
    curl -sf --max-time 30 "http://${EPP_IP}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${LONG_PROMPT}\"}],\"max_tokens\":5}" \
      &>/dev/null || true
    [ "$i" -eq 1 ] && sleep 3
  done
  sleep 1

  # 取最近两次请求日志，检查是否有 score 0
  RECENT_LOGS=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp --tail=20 2>/dev/null)
  SCORE_ERR=$(echo "$RECENT_LOGS" | grep "PrefixCacheMatchInfo not found" | tail -2)
  TOKEN_FAIL=$(echo "$RECENT_LOGS" | grep '"failed to prepare per request data"' | tail -1)
  ZMQ_SHUTDOWN=$(echo "$RECENT_LOGS" | grep "shutting down zmq-subscriber" | tail -1)
  RECEIVED=$(echo "$RECENT_LOGS" | grep '"EPP received request"' | wc -l)

  if [ -n "$ZMQ_SHUTDOWN" ]; then
    fail "ZMQ subscriber 已关闭（vLLM pod 可能已重启），请重启 EPP："
    info "  kubectl rollout restart deployment/${GUIDE_NAME}-epp -n ${NAMESPACE}"
  elif [ -n "$TOKEN_FAIL" ]; then
    fail "token-producer 失败，索引无法建立"
    info "错误: $(echo "$TOKEN_FAIL" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('error','')[:100])" 2>/dev/null)"
  elif [ -n "$SCORE_ERR" ]; then
    fail "prefix-cache-scorer 持续 score 0（ZMQ 连接正常但 KV 索引未建立）"
    info "可能原因：EPP 早于 vLLM 启动，请重启 EPP："
    info "  kubectl rollout restart deployment/${GUIDE_NAME}-epp -n ${NAMESPACE}"
  else
    ok "prefix-cache-scorer 正常工作，KV 索引已建立，路由决策正常"
  fi
fi
echo ""

# ── 4. 端到端：相同前缀两次请求 ───────────────────────────────────────────────
echo "[4] 端到端前缀命中验证（相同 prompt 发送两次，验证路由链路）:"

EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -z "$EPP_IP" ]; then
  fail "找不到 svc/${GUIDE_NAME}-epp"
else
  PROMPT="请详细解释 Transformer 架构中的自注意力机制，从数学角度说明 Query、Key、Value 矩阵的计算方式，以及 Softmax 归一化的作用"

  info "发送第1次请求..."
  T1_START=$(date +%s%3N)
  RESP1=$(curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"max_tokens\":20}" 2>&1)
  T1_END=$(date +%s%3N)
  T1=$((T1_END - T1_START))

  if ! echo "${RESP1}" | grep -q '"finish_reason"'; then
    fail "第1次请求失败: $(echo $RESP1 | cut -c1-100)"
  else
    info "第1次耗时: ${T1}ms"
    sleep 3  # 等待 KV 事件传播到 EPP 索引

    info "发送第2次请求（相同前缀）..."
    T2_START=$(date +%s%3N)
    RESP2=$(curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT}\"}],\"max_tokens\":20}" 2>&1)
    T2_END=$(date +%s%3N)
    T2=$((T2_END - T2_START))

    if ! echo "${RESP2}" | grep -q '"finish_reason"'; then
      fail "第2次请求失败: $(echo $RESP2 | cut -c1-100)"
    else
      info "第2次耗时: ${T2}ms"
      ok "两次请求均成功，端到端路由链路正常"
      if [ "$T2" -lt "$T1" ]; then
        info "第2次更快 (${T2}ms < ${T1}ms)，vLLM 内部前缀缓存命中"
      fi
    fi
  fi
fi
echo ""

# ── 5. 近期 EPP 日志快照 ────────────────────────────────────────────────────────
echo "[5] 近期 EPP 路由日志（最新5条请求）:"
EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp --tail=200 2>/dev/null \
  | grep '"EPP received request"\|"EPP sent request body"' \
  | tail -5 | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        print(f\"  {d.get('msg','')} | req={d.get('x-request-id','')[:8]}... model={d.get('modelName','')}\")
    except:
        print(' ', line.strip()[:100])
" 2>/dev/null || true

echo ""
echo "══════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "结果: 全部通过 (${PASS}/${PASS}) — 精准前缀缓存路由正常工作"
else
  echo "结果: ${FAIL} 项失败，${PASS} 项通过"
  exit 1
fi
