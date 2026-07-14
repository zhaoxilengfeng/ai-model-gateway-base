#!/usr/bin/env bash
# healthcheck.sh — 快速检查 llm-d 集群状态并发送推理请求
#
# 用法:
#   ./healthcheck.sh                  # 检查 config.yaml 中的 llmd 网关
#   ./healthcheck.sh --gateway aibrix # 检查 aibrix 网关
#   ./healthcheck.sh --endpoint http://10.111.96.40 --model qwen25-7b-instruct

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

GREEN=$(python3 -c "import sys; sys.stdout.write(chr(27)+'[32m')")
RED=$(python3 -c "import sys; sys.stdout.write(chr(27)+'[31m')")
YELLOW=$(python3 -c "import sys; sys.stdout.write(chr(27)+'[33m')")
RESET=$(python3 -c "import sys; sys.stdout.write(chr(27)+'[0m')")

ok()   { echo "  ${GREEN}✓${RESET} $*"; }
fail() { echo "  ${RED}✗${RESET} $*"; }
warn() { echo "  ${YELLOW}!${RESET} $*"; }

# --- 参数解析 ---
GATEWAY="llmd"
ENDPOINT=""
MODEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gateway)  GATEWAY="$2"; shift 2 ;;
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# 从 config.yaml 读取（若未手动指定）
yaml_get() {
    python3 -c "
import yaml
with open('${CONFIG}') as f:
    d = yaml.safe_load(f)
keys = '$1'.lstrip('.').split('.')
v = d
for k in keys:
    v = v[k]
print(v)
" 2>/dev/null || echo ""
}

[[ -z "$ENDPOINT" ]] && ENDPOINT=$(yaml_get ".${GATEWAY}.endpoint_url")
[[ -z "$MODEL" ]]    && MODEL=$(yaml_get ".${GATEWAY}.model")
NAMESPACE=$(yaml_get ".${GATEWAY}.namespace")

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          llm-d 集群健康检查                      ║"
echo "╚══════════════════════════════════════════════════╝"
echo "  网关:     $GATEWAY"
echo "  Endpoint: $ENDPOINT"
echo "  Model:    $MODEL"
echo "  NS:       $NAMESPACE"
echo ""

PASS=0
FAIL=0

# --- 1. K8s Pod 状态 ---
echo "▶ K8s Pod 状态"
if [[ -n "$NAMESPACE" ]]; then
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')
        if [[ "$status" == "Running" ]]; then
            ok "$name  ($ready)  $status"
            PASS=$((PASS+1))
        elif [[ "$status" == "Completed" || "$status" == "Succeeded" ]]; then
            warn "$name  ($ready)  $status  (已完成，可清理)"
        else
            fail "$name  ($ready)  $status"
            FAIL=$((FAIL+1))
        fi
    done < <(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "^$" || true)
    [[ $PASS -eq 0 && $FAIL -eq 0 ]] && warn "namespace '$NAMESPACE' 中没有 pod"
else
    warn "未配置 namespace，跳过 pod 检查"
fi

# --- 2. /v1/models 接口 ---
echo ""
echo "▶ 模型接口检查"
MODELS_RESP=$(curl -s --max-time 5 "${ENDPOINT}/v1/models" 2>/dev/null || echo "")
if echo "$MODELS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); ids=[m['id'] for m in d['data']]; print('\n'.join(ids))" 2>/dev/null | grep -q .; then
    MODELS=$(echo "$MODELS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['id']) for m in d['data']]" 2>/dev/null)
    while IFS= read -r m; do
        ok "模型已注册: $m"
        PASS=$((PASS+1))
    done <<< "$MODELS"

    # 验证目标模型存在
    if ! echo "$MODELS" | grep -q "^${MODEL}$"; then
        warn "目标模型 '$MODEL' 不在已注册列表中"
    fi
else
    fail "/v1/models 请求失败（endpoint: ${ENDPOINT}）"
    FAIL=$((FAIL+1))
fi

# --- 3. 推理请求测试 ---
echo ""
echo "▶ 推理请求测试"
START=$(date +%s%3N)
INFER_RESP=$(curl -s --max-time 30 "${ENDPOINT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with exactly one word: hello\"}],\"max_tokens\":10,\"stream\":false}" \
    2>/dev/null || echo "")
END=$(date +%s%3N)
LATENCY=$((END - START))

if CONTENT=$(echo "$INFER_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
" 2>/dev/null); then
    PROMPT_TOKENS=$(echo "$INFER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['prompt_tokens'])" 2>/dev/null || echo "?")
    COMPL_TOKENS=$(echo "$INFER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "?")
    ok "推理成功  耗时: ${LATENCY}ms  输入: ${PROMPT_TOKENS} tokens  输出: ${COMPL_TOKENS} tokens"
    ok "模型回复: \"${CONTENT}\""
    PASS=$((PASS+1))
else
    fail "推理请求失败（耗时: ${LATENCY}ms）"
    [[ -n "$INFER_RESP" ]] && echo "    响应: $(echo "$INFER_RESP" | head -c 200)"
    FAIL=$((FAIL+1))
fi

# --- 4. vLLM metrics ---
echo ""
echo "▶ vLLM 指标采样"
METRICS_PORT=$(yaml_get '.defaults.metrics_port' 2>/dev/null || echo "8000")
POD_IP=$(kubectl get pods -n "$NAMESPACE" -l "llm-d.ai/model=${MODEL}" \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")

if [[ -n "$POD_IP" ]]; then
    METRICS=$(curl -s --max-time 3 "http://${POD_IP}:${METRICS_PORT}/metrics" 2>/dev/null || echo "")
    if [[ -n "$METRICS" ]]; then
        KV_UTIL=$(echo "$METRICS" | grep "^vllm:kv_cache_usage_perc" | awk '{printf "%.1f%%", $2*100}')
        RUNNING=$(echo "$METRICS" | grep "^vllm:num_requests_running" | awk '{print $2}')
        WAITING=$(echo "$METRICS" | grep "^vllm:num_requests_waiting{" | head -1 | awk '{print $2}')
        PREFIX_Q=$(echo "$METRICS" | grep "^vllm:prefix_cache_queries_total" | awk '{print $2}')
        PREFIX_H=$(echo "$METRICS" | grep "^vllm:prefix_cache_hits_total" | awk '{print $2}')

        ok "Pod IP: $POD_IP  KV cache 使用率: ${KV_UTIL:-?}"
        ok "运行中请求: ${RUNNING:-0}  等待中: ${WAITING:-0}"
        if [[ -n "$PREFIX_Q" && "$PREFIX_Q" != "0" ]]; then
            HIT_RATE=$(python3 -c "print(f'{float(\"${PREFIX_H:-0}\")/float(\"${PREFIX_Q}\")*100:.1f}%')" 2>/dev/null || echo "?")
            ok "前缀缓存命中率: $HIT_RATE  (${PREFIX_H:-0}/${PREFIX_Q} tokens)"
        else
            warn "前缀缓存: 暂无查询数据"
        fi
        PASS=$((PASS+1))
    else
        warn "无法访问 vLLM metrics (${POD_IP}:${METRICS_PORT})"
    fi
else
    warn "找不到 vLLM pod（label: llm-d.ai/model=${MODEL}）"
fi

# --- 汇总 ---
echo ""
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
    echo "  ${GREEN}━━ 全部通过 $PASS/$TOTAL ━━${RESET}"
else
    echo "  ${RED}━━ $FAIL 项失败，$PASS/$TOTAL 通过 ━━${RESET}"
fi
echo ""
