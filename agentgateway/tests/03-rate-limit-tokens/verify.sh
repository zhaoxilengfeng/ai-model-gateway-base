#!/usr/bin/env bash
# 03-rate-limit-tokens/verify.sh — 验证 Token 级限流（1000 token/min）
#
# 注意：token 限流基于上一个请求完成后的累计数，对"当前"请求不生效
# 发送 5 个大 output 请求（每个约 300 token），累计超过 1000 后触发 429

set -euo pipefail
NS="llm-d-precise-prefix-gw"
GW_URL="http://116.198.67.18:31273"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "=== 验证：Token 级限流（1000 token/min）==="
echo ""
echo "▶ Step 1: 创建 Token 限流 Policy"
kubectl apply -f "${SCRIPT_DIR}/policy-rate-limit-tokens.yaml" 2>&1 | grep -v Warning
echo "    等待 Policy 生效（10s）..."
sleep 10

echo "▶ Step 2: 连续发送请求（每次要求输出 300 token，累计超 1000 后触发 429）"
PASS=0; RATE_LIMITED=0; TOTAL_TOKENS=0
for i in $(seq 1 6); do
  RESP=$(curl -s --max-time 60 "${GW_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"请用中文写一篇300字以上的文章介绍人工智能\"}],\"max_tokens\":300,\"stream\":false}" 2>/dev/null)
  STATUS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('code',200) if 'error' in d else 200)" 2>/dev/null || echo "err")
  TOKENS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('usage',{}).get('total_tokens',0))" 2>/dev/null || echo 0)
  TOTAL_TOKENS=$((TOTAL_TOKENS + TOKENS))
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${GW_URL}/v1/models" 2>/dev/null)
  if echo "$RESP" | grep -q '"choices"'; then
    PASS=$((PASS+1))
    echo "    req #$i → 成功  tokens=${TOKENS}  累计=${TOTAL_TOKENS}"
  elif echo "$RESP" | grep -q '429\|Too Many\|rate'; then
    RATE_LIMITED=$((RATE_LIMITED+1))
    echo "    req #$i → 429 限流触发  累计=${TOTAL_TOKENS}"
  else
    echo "    req #$i → 其他: $(echo "$RESP" | head -c 100)"
  fi
done

echo ""
echo "  结果: 成功=${PASS}  限流(429)=${RATE_LIMITED}"
if [[ $RATE_LIMITED -gt 0 ]]; then
  ok "Token 限流生效，累计超过 1000 token 后触发 429"
else
  fail "未触发 Token 限流（可能需要更多请求或调小 token 上限）"
fi
echo ""
echo "清理: kubectl delete agentgatewaypolicy rate-limit-tokens-policy -n ${NS}"
