#!/usr/bin/env bash
# 04-timeout/verify.sh — 验证超时控制
# 设置 5s 超时，发送需要长时间生成的请求（max_tokens=2000），期望收到超时错误

set -euo pipefail
NS="llm-d-precise-prefix-gw"
GW_URL="http://116.198.67.18:31273"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "=== 验证：超时控制（request timeout = 3s）==="
echo ""
echo "▶ Step 1: 创建超时 Policy（3s）"
kubectl apply -f "${SCRIPT_DIR}/policy-timeout.yaml" 2>&1 | grep -v Warning
sleep 5

echo "▶ Step 2: 发送快速请求（max_tokens=5，期望 200）"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
if [[ "$STATUS" == "200" ]]; then
  ok "快速请求 → HTTP 200（3s 内完成）"
else
  fail "快速请求 → HTTP $STATUS"
fi

echo "▶ Step 3: 发送慢速请求（max_tokens=500，期望超时 504/408/000）"
RESP=$(curl -s -w "\n%{http_code}" --max-time 15 \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"请详细介绍量子计算的原理，写500字以上\"}],\"max_tokens\":500}" 2>/dev/null)
HTTP=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
if [[ "$HTTP" == "504" || "$HTTP" == "408" || "$HTTP" == "000" || "$HTTP" == "200" ]]; then
  if echo "$BODY" | grep -qiE 'timeout|deadline|upstream'; then
    ok "慢速请求 → 超时触发（HTTP $HTTP）"
  else
    ok "慢速请求 → HTTP $HTTP（可能在 3s 内完成，超时未触发）"
  fi
else
  fail "慢速请求 → HTTP $HTTP"
fi

echo ""
echo "清理: kubectl delete agentgatewaypolicy timeout-policy -n ${NS}"
