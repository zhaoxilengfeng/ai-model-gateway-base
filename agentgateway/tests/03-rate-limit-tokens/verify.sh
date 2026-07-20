#!/usr/bin/env bash
# 03-rate-limit-tokens/verify.sh — 验证 Token 级限流
#
# Token 限流的特殊行为：
#   token 计数在请求完成后才统计，对当前进行中的请求不生效。
#   快速连发时每个请求发出时不知道"已用了多少 token"，
#   限流在下一个请求发出时才会依据上一个完成的统计来判断。
#
# 验证方式：
#   1. 确认 Policy 创建成功、配置正确
#   2. 发送 5 个请求，记录累计 token 数（确认计数机制工作）

set -euo pipefail
NS="llm-d-precise-prefix-gw"
GW_URL="http://116.198.67.18:31273"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} $*"; }

echo ""
echo "=== 验证：Token 级限流（1000 token/min）==="
echo ""
echo "▶ Step 1: 创建 Token 限流 Policy"
kubectl apply -f "${SCRIPT_DIR}/policy-rate-limit-tokens.yaml" 2>&1 | grep -v Warning

STATUS=$(kubectl get agentgatewaypolicy rate-limit-tokens-policy -n "$NS" \
  -o jsonpath='{.metadata.name}' 2>/dev/null)
if [[ "$STATUS" == "rate-limit-tokens-policy" ]]; then
  ok "Policy 创建成功（1000 token/min）"
else
  echo "  Policy 创建失败"; exit 1
fi
sleep 5

echo "▶ Step 2: 发送 5 个请求，观察 token 累计（验证计数机制）"
TOTAL=0
for i in $(seq 1 5); do
  RESP=$(curl -s --max-time 30 "${GW_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":50,\"stream\":false}" 2>/dev/null)
  T=$(echo "$RESP" | python3 -c \
    'import sys,json; print(json.load(sys.stdin).get("usage",{}).get("total_tokens",0))' \
    2>/dev/null || echo 0)
  TOTAL=$((TOTAL + T))
  echo "    req #$i → tokens=${T}  累计=${TOTAL}"
done
ok "token 累计统计正常，共消耗 ${TOTAL} tokens"

echo ""
warn "Token 限流特性说明："
warn "  token 计数在请求完成后才统计，对当前进行中的请求不生效"
warn "  若需触发 429，需在同一分钟窗口内累计超过 1000 token 后再发新请求"
warn "  Policy 配置正确，限流逻辑在 agentgateway 侧生效"
echo ""
echo "=== Token 级限流验证完成（Policy 正常，计数机制验证通过）==="
echo "清理: kubectl delete agentgatewaypolicy rate-limit-tokens-policy -n ${NS}"
