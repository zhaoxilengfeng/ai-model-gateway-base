#!/bin/bash
# verify-precise-prefix.sh — 验证精准前缀缓存路由是否正常工作
#
# 检测逻辑：
#   1. ZMQ 连接：EPP 是否订阅了所有 vLLM pod 的 KV 事件 socket
#   2. token-producer：render service 是否能正常 tokenize
#   3. 路由集中性验证（核心）：发 8 次相同前缀请求，观察是否集中路由到同一 pod
#      通过对比各 pod 的 vllm:prefix_cache_queries_total 增量来判断
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
kubectl get pods -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" -o wide
echo ""

# ── 1. ZMQ 连接检查（所有 vLLM pod）─────────────────────────────────────────
echo "[1] ZMQ 连接检查（EPP 是否订阅了所有 vLLM pod 的 KV 事件 socket）:"

VLLM_IPS=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
  -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)
VLLM_COUNT=$(echo $VLLM_IPS | wc -w)

if [ -z "$VLLM_IPS" ]; then
  fail "找不到 vLLM pod（label llm-d.ai/model=${MODEL}）"
else
  info "vLLM pod 数量: ${VLLM_COUNT}"
  EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
  if [ -z "$EPP_POD" ]; then
    fail "找不到运行中的 EPP pod"
  else
    ZMQ_CONNECTED=0
    for ip in $VLLM_IPS; do
      ZMQ_LOG=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null \
        | grep "Connected subscriber socket" | grep "${ip}:5556" | tail -1)
      ZMQ_SHUTDOWN=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null \
        | grep "shutting down zmq-subscriber" | tail -1)
      if [ -n "$ZMQ_LOG" ] && [ -z "$ZMQ_SHUTDOWN" ]; then
        info "ZMQ 已连接: tcp://${ip}:5556"
        ZMQ_CONNECTED=$((ZMQ_CONNECTED+1))
      else
        info "ZMQ 未连接: ${ip}:5556（ZMQ_SHUTDOWN=${ZMQ_SHUTDOWN:+yes}）"
      fi
    done
    if [ "$ZMQ_CONNECTED" -eq "$VLLM_COUNT" ]; then
      ok "全部 ${VLLM_COUNT} 个 vLLM pod ZMQ 已连接"
    elif [ "$ZMQ_CONNECTED" -gt 0 ]; then
      ok "${ZMQ_CONNECTED}/${VLLM_COUNT} 个 pod ZMQ 已连接（部分连接仍可路由）"
    else
      fail "所有 pod ZMQ 未连接，请重启 EPP：kubectl rollout restart deployment/${GUIDE_NAME}-epp -n ${NAMESPACE}"
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
  RENDER_MODEL=$(curl -sf --max-time 5 "http://${RENDER_IP}:8000/v1/models" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "")
  if [ -z "$RENDER_MODEL" ]; then
    fail "render /v1/models 无响应"
  else
    EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
    TOKEN_ERR=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp --tail=100 2>/dev/null \
      | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        msg = d.get('msg','')
        err = d.get('error','')
        if 'tokenization failed' in err or ('does not exist' in err and 'token' in str(d).lower()):
            print(err[:120])
    except: pass
" 2>/dev/null | tail -1)
    if [ -n "$TOKEN_ERR" ]; then
      fail "token-producer 报错（render 模型名不一致）: render=${RENDER_MODEL}"
      info "$(echo "$TOKEN_ERR" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('error','')[:120])" 2>/dev/null)"
    else
      ok "token-producer 正常，render 模型名: ${RENDER_MODEL}"
    fi
  fi
fi
echo ""

# ── 3. 路由集中性验证（核心：精准前缀路由生效的决定性证据）────────────────────
echo "[3] 路由集中性验证（核心检查）:"
info "原理：相同前缀请求在第一次处理后，EPP 应将后续请求路由到有 KV cache 的 pod"
info "方法：采集基准值 → 发 8 次相同前缀请求 → 比对各 pod 新增请求数分布"
echo ""

EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "$EPP_IP" ]; then
  fail "找不到 svc/${GUIDE_NAME}-epp"
else
  # 采集各 pod 基准值
  declare -A Q_BEFORE H_BEFORE POD_NODE
  VLLM_PODS=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name},{.status.podIP},{.spec.nodeName} {end}' 2>/dev/null)

  for entry in $VLLM_PODS; do
    pname=$(echo $entry | cut -d, -f1)
    pip=$(echo $entry | cut -d, -f2)
    pnode=$(echo $entry | cut -d, -f3)
    POD_NODE[$pip]="${pnode}"
    Q_BEFORE[$pip]=$(curl -sf --max-time 3 "http://${pip}:8000/metrics" 2>/dev/null \
      | grep "^vllm:prefix_cache_queries_total{" | awk '{print $2+0}')
    H_BEFORE[$pip]=$(curl -sf --max-time 3 "http://${pip}:8000/metrics" 2>/dev/null \
      | grep "^vllm:prefix_cache_hits_total{" | awk '{print $2+0}')
    info "基准 ${pnode}(${pip}): queries=${Q_BEFORE[$pip]} hits=${H_BEFORE[$pip]}"
  done

  # 先发一次请求建立初始 KV cache
  LONG_PREFIX="请你详细解释 Transformer 架构中多头自注意力机制的数学原理，包括 Query Key Value 矩阵的计算方式、Softmax 归一化、缩放点积注意力的完整推导过程，以及为什么要除以根号 dk，还有位置编码的作用。"
  curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${LONG_PREFIX}\"}],\"max_tokens\":10}" \
    &>/dev/null || true
  sleep 3  # 等 KV 事件传播

  # 发 8 次相同请求
  info "发送 8 次相同前缀请求..."
  for i in $(seq 1 8); do
    curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${LONG_PREFIX}\"}],\"max_tokens\":10}" \
      &>/dev/null || true
    echo -n "."
    sleep 1
  done
  echo ""
  sleep 2

  # 采集测试后值并分析
  declare -A Q_AFTER H_AFTER Q_DELTA H_DELTA
  TOTAL_NEW=0
  MAX_NEW=0
  MAX_IP=""

  for entry in $VLLM_PODS; do
    pip=$(echo $entry | cut -d, -f2)
    Q_AFTER[$pip]=$(curl -sf --max-time 3 "http://${pip}:8000/metrics" 2>/dev/null \
      | grep "^vllm:prefix_cache_queries_total{" | awk '{print $2+0}')
    H_AFTER[$pip]=$(curl -sf --max-time 3 "http://${pip}:8000/metrics" 2>/dev/null \
      | grep "^vllm:prefix_cache_hits_total{" | awk '{print $2+0}')
    Q_DELTA[$pip]=$(echo "${Q_AFTER[$pip]} ${Q_BEFORE[$pip]}" | awk '{print $1-$2}')
    H_DELTA[$pip]=$(echo "${H_AFTER[$pip]} ${H_BEFORE[$pip]}" | awk '{print $1-$2}')
    TOTAL_NEW=$((TOTAL_NEW + ${Q_DELTA[$pip]%.*}))
    if [ "${Q_DELTA[$pip]%.*}" -gt "$MAX_NEW" ]; then
      MAX_NEW="${Q_DELTA[$pip]%.*}"
      MAX_IP="$pip"
    fi
  done

  echo ""
  info "请求分布结果："
  for entry in $VLLM_PODS; do
    pip=$(echo $entry | cut -d, -f2)
    qd=${Q_DELTA[$pip]%.*}
    hd=${H_DELTA[$pip]%.*}
    node=${POD_NODE[$pip]}
    if [ "$qd" -gt 0 ]; then
      hit_pct=$(echo "$hd $qd" | awk '{printf "%.1f", $1/$2*100}')
      info "  ${node}(${pip}): 新增 ${qd} 条，命中 ${hd} 条（命中率 ${hit_pct}%）"
    else
      info "  ${node}(${pip}): 新增 0 条"
    fi
  done

  echo ""
  if [ "$TOTAL_NEW" -eq 0 ]; then
    fail "无法获取各 pod 请求增量，metrics 可能不可达"
  else
    RATIO=$(echo "$MAX_NEW $TOTAL_NEW" | awk '{printf "%d", $1/$2*100}')
    if [ "$RATIO" -ge 88 ]; then
      ok "路由高度集中：${MAX_NEW}/${TOTAL_NEW} 条路由到 ${POD_NODE[$MAX_IP]}（${RATIO}%）"
      ok "精准前缀路由生效 — EPP 将相同前缀的请求集中路由到有 KV cache 的 pod"
    elif [ "$RATIO" -ge 60 ]; then
      ok "路由明显倾向：${MAX_NEW}/${TOTAL_NEW} 条路由到 ${POD_NODE[$MAX_IP]}（${RATIO}%）"
      info "倾向明显但不绝对，符合多因素加权评分（prefix × 3 + queue × 2 + kv-util × 2）的预期"
    else
      fail "请求均匀分布（最大集中度 ${RATIO}%），精准前缀路由未生效"
      info "检查：1) EPP 是否在 vLLM 之后启动  2) ZMQ 是否收到 KV 事件  3) token-producer 是否正常"
    fi
  fi
fi
echo ""

# ── 4. 近期 EPP 日志快照 ────────────────────────────────────────────────────────
echo "[4] 近期 EPP 路由日志（最新5条）:"
EPP_POD=$(kubectl get pods -n "${NAMESPACE}" | grep "${GUIDE_NAME}-epp" | grep Running | head -1 | awk '{print $1}')
kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp --tail=100 2>/dev/null \
  | grep '"EPP received request"' \
  | tail -5 | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        print(f\"  req={d.get('x-request-id','')[:12]}...\")
    except:
        print(' ', line.strip()[:80])
" 2>/dev/null || true

echo ""
echo "══════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "结果: 全部通过 (${PASS}/${PASS}) — 精准前缀缓存路由正常工作"
else
  echo "结果: ${FAIL} 项失败，${PASS} 项通过"
  exit 1
fi
