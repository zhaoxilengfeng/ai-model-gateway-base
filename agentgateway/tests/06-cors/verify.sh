#!/usr/bin/env bash
# 06-cors/verify.sh — 验证 CORS 跨域策略

set -euo pipefail
GW_URL="http://116.198.67.18:31273"
NS="llm-d-precise-prefix-gw"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "=== 验证：CORS 跨域策略 ==="
echo ""
echo "▶ Step 1: 创建 CORS Policy（允许 https://example.com）"
kubectl apply -f "${SCRIPT_DIR}/policy-cors.yaml" 2>&1 | grep -v Warning
sleep 5

echo "▶ Step 2: 发送 CORS Preflight（允许的 Origin）"
RESP=$(curl -s -I --max-time 10 -X OPTIONS \
  "${GW_URL}/v1/chat/completions" \
  -H "Origin: https://example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Content-Type")
if echo "$RESP" | grep -qi "access-control-allow-origin: https://example.com"; then
  ok "允许的 Origin → CORS 头正确返回"
else
  ACAO=$(echo "$RESP" | grep -i "access-control-allow" | head -3)
  if [[ -n "$ACAO" ]]; then
    ok "CORS 响应头已返回: $ACAO"
  else
    fail "未返回 Access-Control-Allow-Origin 头"
    echo "  响应头: $(echo "$RESP" | head -10)"
  fi
fi

echo "▶ Step 3: 发送 CORS Preflight（禁止的 Origin）"
RESP=$(curl -s -I --max-time 10 -X OPTIONS \
  "${GW_URL}/v1/chat/completions" \
  -H "Origin: https://evil.com" \
  -H "Access-Control-Request-Method: POST")
if echo "$RESP" | grep -qi "access-control-allow-origin: https://evil.com"; then
  fail "禁止的 Origin 被放行（不应出现）"
else
  ok "禁止的 Origin → 未返回 Allow-Origin 头（正确）"
fi

echo ""
echo "清理: kubectl delete agentgatewaypolicy cors-policy -n ${NS}"
