#!/bin/bash
# test-routing-comparison.sh — 对比精准前缀路由 vs 随机路由的分布差异
#
# 用法：
#   bash test-routing-comparison.sh [选项]
#
# 选项：
#   -n NAMESPACE    K8s namespace（默认: llm-d-precise-prefix）
#   -g GUIDE_NAME   Helm release 名称（默认: precise-prefix-cache-routing）
#   -m MODEL        模型名（默认: qwen25-7b-instruct）
#   -r REQUESTS     每轮请求次数（默认: 10）
#   -t MAX_TOKENS   每次请求的 max_tokens（默认: 5）
#   -h              显示帮助
#
# 测试逻辑：
#   轮1（随机路由基准）: 发 N 次完全不同的 prompt → 预期均匀分布
#   轮2（精准前缀路由）: 发 N 次相同长前缀 prompt → 预期集中到单个 pod
#
# 两轮对比结果即可证明精准前缀路由的效果是由 KV cache 驱动的。

NAMESPACE="${NAMESPACE:-llm-d-precise-prefix}"
GUIDE_NAME="${GUIDE_NAME:-precise-prefix-cache-routing}"
MODEL="${MODEL:-qwen25-7b-instruct}"
REQUESTS="${REQUESTS:-10}"
MAX_TOKENS="${MAX_TOKENS:-5}"

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \?//'
  exit 0
}

while getopts "n:g:m:r:t:h" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    g) GUIDE_NAME="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    r) REQUESTS="$OPTARG" ;;
    t) MAX_TOKENS="$OPTARG" ;;
    h) usage ;;
    *) echo "未知选项，使用 -h 查看帮助" >&2; exit 1 ;;
  esac
done

# ── 工具函数 ─────────────────────────────────────────────────────────────────
info()    { echo "  $*"; }
section() { echo ""; echo "─── $* ───"; }

get_request_count() {
  local ip=$1
  curl -sf --max-time 3 "http://${ip}:8000/metrics" 2>/dev/null \
    | grep "^vllm:request_success_total{" | awk '{sum+=$2} END{print sum+0}'
}

send_request() {
  local epp_ip=$1 prompt=$2
  curl -sf --max-time 60 "${epp_ip}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}],\"max_tokens\":${MAX_TOKENS}}" \
    &>/dev/null || true
}

print_distribution() {
  local -n _pods=$1
  local -n _before=$2
  local -n _after=$3
  local -n _nodes=$4
  local total=0 max_n=0 max_ip=""

  for entry in ${_pods}; do
    pip=$(echo $entry | cut -d, -f2)
    delta=$(echo "${_after[$pip]} ${_before[$pip]}" | awk '{printf "%d", $1-$2}')
    total=$((total + delta))
    if [ "$delta" -gt "$max_n" ]; then max_n=$delta; max_ip=$pip; fi
  done

  for entry in ${_pods}; do
    pip=$(echo $entry | cut -d, -f2)
    node=${_nodes[$pip]}
    delta=$(echo "${_after[$pip]} ${_before[$pip]}" | awk '{printf "%d", $1-$2}')
    pct=$(echo "$delta $total" | awk '{if($2>0) printf "%.0f%%", $1/$2*100; else print "0%"}')
    bar=$(python3 -c "n=int(${delta}*30/${total} if ${total}>0 else 0); print('█'*n + '░'*(30-n))" 2>/dev/null || echo "")
    info "  ${node}: ${delta}/${total} 条 (${pct})  ${bar}"
  done

  if [ "$total" -gt 0 ]; then
    ratio=$(echo "$max_n $total" | awk '{printf "%d", $1/$2*100}')
    echo "  最大集中度: ${ratio}%（${_nodes[$max_ip]}）"
  fi
  echo "  总计: ${total} 条"
}

# ── 初始化 ────────────────────────────────────────────────────────────────────
EPP_IP=$(kubectl get svc "${GUIDE_NAME}-epp" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
EPP_URL="http://${EPP_IP}"

if [ -z "$EPP_IP" ]; then
  echo "ERROR: 找不到 svc/${GUIDE_NAME}-epp，请检查 namespace 和 guide name" >&2
  exit 1
fi

VLLM_PODS=$(kubectl get pod -n "${NAMESPACE}" -l "llm-d.ai/model=${MODEL}" \
  -o jsonpath='{range .items[*]}{.metadata.name},{.status.podIP},{.spec.nodeName} {end}' 2>/dev/null)
POD_COUNT=$(echo $VLLM_PODS | wc -w)

if [ "$POD_COUNT" -lt 2 ]; then
  echo "ERROR: 需要至少 2 个 vLLM pod 才能对比路由分布（当前 ${POD_COUNT} 个）" >&2
  exit 1
fi

declare -A POD_NODE
for entry in $VLLM_PODS; do
  pip=$(echo $entry | cut -d, -f2)
  pnode=$(echo $entry | cut -d, -f3)
  POD_NODE[$pip]="${pnode}"
done

echo "════════════════════════════════════════════════════════"
echo "  路由策略对比测试"
echo "════════════════════════════════════════════════════════"
echo "  namespace  : ${NAMESPACE}"
echo "  model      : ${MODEL}"
echo "  vLLM pods  : ${POD_COUNT} 个"
echo "  每轮请求数  : ${REQUESTS} 次"
echo ""

for entry in $VLLM_PODS; do
  pip=$(echo $entry | cut -d, -f2)
  info "  pod: ${POD_NODE[$pip]}(${pip})"
done

# ════════════════════════════════════════════════════════════
# 轮1：随机路由基准（每次发完全不同的 prompt）
# ════════════════════════════════════════════════════════════
section "轮1：随机路由基准（不同 prompt，无共享前缀）"
echo "  预期：请求均匀分布到各 pod"
echo ""

declare -A R1_BEFORE R1_AFTER
for entry in $VLLM_PODS; do
  pip=$(echo $entry | cut -d, -f2)
  R1_BEFORE[$pip]=$(get_request_count $pip)
done

info "发送 ${REQUESTS} 次不同 prompt..."
for i in $(seq 1 ${REQUESTS}); do
  # 每次 prompt 都不同（加入序号和随机内容），确保没有共享前缀
  RANDOM_PROMPTS=(
    "第${i}题：请介绍一下${i}月份的气候特点"
    "问题${i}：用一句话解释什么是第${i}代计算机"
    "No.${i} 请列举${i}个常见的编程语言"
    "Q${i}: 描述一下数字${i}在数学中的特殊性质"
    "话题${i}：聊聊${i}这个数字在文化中的含义"
  )
  PROMPT="${RANDOM_PROMPTS[$((i % 5))]}"
  send_request "$EPP_URL" "$PROMPT"
  echo -n "."
  sleep 0.5
done
echo " done"
sleep 2

for entry in $VLLM_PODS; do
  pip=$(echo $entry | cut -d, -f2)
  R1_AFTER[$pip]=$(get_request_count $pip)
done

echo ""
print_distribution VLLM_PODS R1_BEFORE R1_AFTER POD_NODE

# ════════════════════════════════════════════════════════════
# 轮2：精准前缀路由（每次发完全相同的长 prompt）
# ════════════════════════════════════════════════════════════
section "轮2：精准前缀路由（相同 prompt，有共享前缀）"
echo "  预期：请求集中路由到有 KV cache 的 pod"
echo ""

declare -A R2_BEFORE R2_AFTER
for entry in $VLLM_PODS; do
  pip=$(echo $entry | cut -d, -f2)
  R2_BEFORE[$pip]=$(get_request_count $pip)
done

LONG_PREFIX="请你详细解释 Transformer 架构中多头自注意力机制的数学原理，包括 Query Key Value 矩阵的计算方式、Softmax 归一化、缩放点积注意力的完整推导过程，以及为什么要除以根号 dk，还有位置编码的作用。"

info "发送初始请求建立 KV cache..."
send_request "$EPP_URL" "$LONG_PREFIX"
sleep 3  # 等 KV 事件传播到 EPP 索引

info "发送 ${REQUESTS} 次相同 prompt..."
for i in $(seq 1 ${REQUESTS}); do
  send_request "$EPP_URL" "$LONG_PREFIX"
  echo -n "."
  sleep 1
done
echo " done"
sleep 2

for entry in $VLLM_PODS; do
  pip=$(echo $entry | cut -d, -f2)
  R2_AFTER[$pip]=$(get_request_count $pip)
done

echo ""
print_distribution VLLM_PODS R2_BEFORE R2_AFTER POD_NODE

# ════════════════════════════════════════════════════════════
# 结论对比
# ════════════════════════════════════════════════════════════
section "对比结论"

calc_max_ratio() {
  local -n _pods=$1
  local -n _before=$2
  local -n _after=$3
  local total=0 max_n=0
  for entry in ${_pods}; do
    pip=$(echo $entry | cut -d, -f2)
    delta=$(echo "${_after[$pip]} ${_before[$pip]}" | awk '{printf "%d", $1-$2}')
    total=$((total + delta))
    [ "$delta" -gt "$max_n" ] && max_n=$delta
  done
  echo "$max_n $total" | awk '{if($2>0) printf "%d", $1/$2*100; else print 0}'
}

RATIO1=$(calc_max_ratio VLLM_PODS R1_BEFORE R1_AFTER)
RATIO2=$(calc_max_ratio VLLM_PODS R2_BEFORE R2_AFTER)

echo ""
printf "  %-20s %s\n" "策略" "最大集中度"
printf "  %-20s %s\n" "────────────────────" "──────────"
printf "  %-20s %d%%\n" "随机路由（不同prompt）" "$RATIO1"
printf "  %-20s %d%%\n" "精准前缀路由（相同prompt）" "$RATIO2"
echo ""

DIFF=$((RATIO2 - RATIO1))
if [ "$RATIO2" -ge 80 ] && [ "$DIFF" -ge 30 ]; then
  echo "  结论：精准前缀路由显著生效 ✓"
  echo "  精准路由集中度（${RATIO2}%）比随机路由（${RATIO1}%）高 ${DIFF} 个百分点"
  echo "  EPP 通过 ZMQ KV 事件感知缓存状态，将相同前缀请求集中路由到命中 pod"
elif [ "$RATIO2" -ge 60 ] && [ "$DIFF" -ge 15 ]; then
  echo "  结论：精准前缀路由有明显倾向 ✓（集中度差 ${DIFF}%）"
  echo "  多因素加权评分下（prefix×3 + queue×2 + kv-util×2），集中不绝对属正常"
else
  echo "  结论：两轮分布差异不明显（差 ${DIFF}%），精准路由效果不确定"
  echo "  建议：增加请求次数（-r 20）或检查 EPP ZMQ 订阅状态"
fi
echo ""
