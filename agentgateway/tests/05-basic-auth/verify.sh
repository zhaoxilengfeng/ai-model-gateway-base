#!/usr/bin/env bash
# 05-basic-auth/verify.sh — 验证 HTTP Basic 认证

set -euo pipefail
NS="llm-d-precise-prefix-gw"
GW_URL="http://116.198.67.18:31273"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "=== 验证：HTTP Basic 认证 ==="
echo ""
echo "▶ Step 1: 创建用户 Secret（admin:password123）"
kubectl apply -f "${SCRIPT_DIR}/basic-auth-secret.yaml" 2>&1 | grep -v Warning
echo "▶ Step 2: 创建 Basic Auth Policy（Strict）"
kubectl apply -f "${SCRIPT_DIR}/policy-basic-auth.yaml" 2>&1 | grep -v Warning
sleep 5

echo "▶ Step 3: 无认证请求（期望 401）"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
[[ "$STATUS" == "401" ]] && ok "无认证 → HTTP 401" || fail "无认证 → HTTP $STATUS（期望 401）"

echo "▶ Step 4: 错误密码（期望 401）"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -u "admin:wrongpass" \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
[[ "$STATUS" == "401" ]] && ok "错误密码 → HTTP 401" || fail "错误密码 → HTTP $STATUS（期望 401）"

echo "▶ Step 5: 正确凭证（期望 200）"
RESP=$(curl -s --max-time 30 -u "admin:password123" \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
if echo "$RESP" | python3 -c "import sys,json; json.load(sys.stdin)['choices']" 2>/dev/null; then
  ok "正确凭证 → 推理成功"
else
  fail "正确凭证 → 失败: $(echo "$RESP" | head -c 150)"
fi

echo ""
echo "清理: kubectl delete agentgatewaypolicy basic-auth-policy -n ${NS} && kubectl delete secret basic-auth-users -n ${NS}"
