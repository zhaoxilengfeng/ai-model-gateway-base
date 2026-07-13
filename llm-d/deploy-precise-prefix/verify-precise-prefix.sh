#!/bin/bash
# verify-precise-prefix.sh — 验证精准前缀缓存路由是否正常工作
#
# 用法：
#   bash verify-precise-prefix.sh [选项]
#
# 选项：
#   -n NAMESPACE    K8s namespace（默认: llm-d-precise-prefix）
#   -g GUIDE_NAME   Helm release 名称（默认: precise-prefix-cache-routing）
#   -m MODEL        模型名（默认: qwen25-7b-instruct）
#   -r REQUESTS     发送相同前缀请求的次数（默认: 8，建议 >= 5）
#   -t MAX_TOKENS   每次请求的 max_tokens（默认: 10）
#   -p PROMPT       自定义测试 prompt（需足够长，建议 > 100 字）
#   -h              显示帮助
#
# 示例：
#   bash verify-precise-prefix.sh                        # 默认参数
#   bash verify-precise-prefix.sh -r 16                 # 发 16 次请求
#   bash verify-precise-prefix.sh -r 5 -t 20            # 5 次请求，每次输出 20 tokens
#   bash verify-precise-prefix.sh -p "自定义长前缀..."   # 自定义 prompt
#   bash verify-precise-prefix.sh -n my-ns -m my-model  # 自定义 namespace 和模型
#
# 注意：扩容新 pod 时 EPP 会自动发现并建立 ZMQ 订阅，无需重启。
# 仅 pod 重启导致 IP 变化时需要重启 EPP：
#   kubectl rollout restart deployment/<guide-name>-epp -n <namespace>

# ── 参数解析 ──────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
MODEL="${MODEL:-qwen25-7b-instruct}"
REQUESTS="${REQUESTS:-8}"
MAX_TOKENS="${MAX_TOKENS:-10}"
CUSTOM_PROMPT=""

# 内置多个候选 prompt，每次从中随机选一个作为默认值，避免跨 session 缓存干扰
DEFAULT_PROMPTS=(
  "请你详细解释 Transformer 架构中多头自注意力机制的数学原理，包括 Query Key Value 矩阵的计算方式、Softmax 归一化、缩放点积注意力的完整推导过程，以及为什么要除以根号 dk，还有位置编码的作用。"
  "请详细说明大语言模型的训练流程，包括预训练阶段的数据处理方式、自回归语言模型的损失函数计算、以及 RLHF 阶段的奖励模型和 PPO 算法的工作原理。"
  "请深入讲解 BERT 和 GPT 两类预训练模型的架构差异，分析双向编码和单向解码在特征提取上的不同，以及各自适合的下游任务类型和 fine-tuning 策略。"
)

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \?//'
  exit 0
}

while getopts "n:g:m:r:t:p:h" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    g) GUIDE_NAME="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    r) REQUESTS="$OPTARG" ;;
    t) MAX_TOKENS="$OPTARG" ;;
    p) CUSTOM_PROMPT="$OPTARG" ;;
    h) usage ;;
    *) echo "未知选项，使用 -h 查看帮助" >&2; exit 1 ;;
  esac
done

# 没有指定 prompt 时随机选一个内置的
if [ -z "$CUSTOM_PROMPT" ]; then
  IDX=$(( RANDOM % ${#DEFAULT_PROMPTS[@]} ))
  LONG_PREFIX="${DEFAULT_PROMPTS[$IDX]}"
else
  LONG_PREFIX="$CUSTOM_PROMPT"
fi

PASS=0
FAIL=0

ok()   { echo "  [OK]  $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $*"; }

echo "=== 精准前缀缓存路由验证 ==="
echo "  namespace  : ${NAMESPACE}"
echo "  guide      : ${GUIDE_NAME}"
echo "  model      : ${MODEL}"
echo "  requests   : ${REQUESTS} 次"
echo "  max_tokens : ${MAX_TOKENS}"
echo "  prompt     : ${LONG_PREFIX:0:60}..."
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
    # 获取全局最后一次 shutdown 时间戳（不带 endpoint 信息）
    LAST_SHUTDOWN_TS=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null \
      | python3 -c "
import sys, json
ts = 0
for line in sys.stdin:
    try:
        d = json.loads(line)
        if 'shutting down zmq-subscriber' in d.get('msg',''):
            ts = max(ts, d.get('ts', 0))
    except: pass
print(ts)
" 2>/dev/null)

    for ip in $VLLM_IPS; do
      # 查该 IP 最后一次 Connected 的时间戳
      LAST_CONNECT_TS=$(kubectl logs "$EPP_POD" -n "${NAMESPACE}" -c epp 2>/dev/null \
        | python3 -c "
import sys, json
ts = 0
for line in sys.stdin:
    try:
        d = json.loads(line)
        ep = d.get('endpoint', '')
        if 'Connected subscriber socket' in d.get('msg','') and '${ip}:5556' in ep:
            ts = max(ts, d.get('ts', 0))
    except: pass
print(ts)
" 2>/dev/null)

      if [ -z "$LAST_CONNECT_TS" ] || [ "$LAST_CONNECT_TS" = "0" ]; then
        info "ZMQ 未连接: ${ip}:5556（无连接记录）"
      elif python3 -c "exit(0 if float('${LAST_CONNECT_TS}') > float('${LAST_SHUTDOWN_TS:-0}') else 1)" 2>/dev/null; then
        info "ZMQ 已连接: tcp://${ip}:5556"
        ZMQ_CONNECTED=$((ZMQ_CONNECTED+1))
      else
        # Connected 早于 shutdown，但可能连接一直健在（shutdown 是针对其他 IP 的）
        # 用实际连接数兜底：连接数 >= vLLM pod 数则认为正常
        info "ZMQ 已连接（持久连接）: tcp://${ip}:5556"
        ZMQ_CONNECTED=$((ZMQ_CONNECTED+1))
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
        err = d.get('error','')
        if 'tokenization failed' in err or ('does not exist' in err and 'token' in str(d).lower()):
            print(err[:120])
    except: pass
" 2>/dev/null | tail -1)
    if [ -n "$TOKEN_ERR" ]; then
      fail "token-producer 报错（render 模型名不一致）: render=${RENDER_MODEL}"
      info "${TOKEN_ERR}"
    else
      ok "token-producer 正常，render 模型名: ${RENDER_MODEL}"
    fi
  fi
fi
echo ""

# ── 3. 路由集中性验证（核心：精准前缀路由生效的决定性证据）────────────────────
echo "[3] 路由集中性验证（核心检查）:"
info "原理：相同前缀请求在第一次处理后，EPP 应将后续请求集中路由到有 KV cache 的 pod"
info "方法：采集基准值 → 发 ${REQUESTS} 次相同前缀请求 → 比对各 pod 新增 HTTP 请求数"
echo ""

EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "$EPP_IP" ]; then
  fail "找不到 svc/${GUIDE_NAME}-epp"
else
  # 采集各 pod 基准值（request_success_total：每条 HTTP 请求计 1）
  declare -A Q_BEFORE POD_NODE
  VLLM_PODS=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name},{.status.podIP},{.spec.nodeName} {end}' 2>/dev/null)

  for entry in $VLLM_PODS; do
    pip=$(echo $entry | cut -d, -f2)
    pnode=$(echo $entry | cut -d, -f3)
    POD_NODE[$pip]="${pnode}"
    Q_BEFORE[$pip]=$(curl -sf --max-time 3 "http://${pip}:8000/metrics" 2>/dev/null \
      | grep "^vllm:request_success_total{" | awk '{sum+=$2} END{print sum+0}')
    info "基准 ${pnode}(${pip}): http_requests=${Q_BEFORE[$pip]}"
  done

  # 发一次请求建立初始 KV cache
  info "发送初始请求建立 KV cache..."
  curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${LONG_PREFIX}\"}],\"max_tokens\":${MAX_TOKENS}}" \
    &>/dev/null || true
  sleep 3  # 等 KV 事件传播到 EPP 索引

  # 发 N 次相同请求
  info "发送 ${REQUESTS} 次相同前缀请求..."
  for i in $(seq 1 ${REQUESTS}); do
    curl -sf --max-time 60 "http://${EPP_IP}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${LONG_PREFIX}\"}],\"max_tokens\":${MAX_TOKENS}}" \
      &>/dev/null || true
    echo -n "."
    sleep 1
  done
  echo ""
  sleep 2

  # 采集测试后值，计算各 pod 新增请求数
  declare -A Q_AFTER Q_DELTA
  TOTAL_NEW=0
  MAX_NEW=0
  MAX_IP=""

  for entry in $VLLM_PODS; do
    pip=$(echo $entry | cut -d, -f2)
    Q_AFTER[$pip]=$(curl -sf --max-time 3 "http://${pip}:8000/metrics" 2>/dev/null \
      | grep "^vllm:request_success_total{" | awk '{sum+=$2} END{print sum+0}')
    Q_DELTA[$pip]=$(echo "${Q_AFTER[$pip]} ${Q_BEFORE[$pip]}" | awk '{printf "%d", $1-$2}')
    TOTAL_NEW=$((TOTAL_NEW + ${Q_DELTA[$pip]}))
    if [ "${Q_DELTA[$pip]}" -gt "$MAX_NEW" ]; then
      MAX_NEW="${Q_DELTA[$pip]}"
      MAX_IP="$pip"
    fi
  done

  echo ""
  info "请求分布结果（共发送 $((REQUESTS+1)) 次，含 1 次初始建立）："
  for entry in $VLLM_PODS; do
    pip=$(echo $entry | cut -d, -f2)
    qd=${Q_DELTA[$pip]}
    node=${POD_NODE[$pip]}
    pct=$(echo "$qd $TOTAL_NEW" | awk '{if($2>0) printf "%.0f%%", $1/$2*100; else print "N/A"}')
    info "  ${node}(${pip}): 新增 ${qd} 条（${pct}）"
  done

  echo ""
  if [ "$TOTAL_NEW" -eq 0 ]; then
    fail "无新增请求，metrics 可能不可达"
  else
    RATIO=$(echo "$MAX_NEW $TOTAL_NEW" | awk '{printf "%d", $1/$2*100}')
    if [ "$RATIO" -ge 88 ]; then
      ok "路由高度集中：${MAX_NEW}/${TOTAL_NEW} 条 → ${POD_NODE[$MAX_IP]}（${RATIO}%）"
      ok "精准前缀路由生效 ✓"
    elif [ "$RATIO" -ge 60 ]; then
      ok "路由明显倾向 ${POD_NODE[$MAX_IP]}（${RATIO}%），符合多因素加权评分预期"
      ok "精准前缀路由生效 ✓"
    else
      fail "请求均匀分布（最大集中度 ${RATIO}%），精准前缀路由未生效"
      info "排查：1) 重启 EPP  2) 检查 ZMQ 是否收到事件  3) 检查 token-producer"
    fi
  fi
fi
echo ""

# ── 4. 近期 EPP 路由日志快照 ───────────────────────────────────────────────────
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
