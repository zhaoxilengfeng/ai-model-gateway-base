#!/usr/bin/env bash
# 07-header-modifier/verify.sh — 验证请求/响应头修改

set -euo pipefail
GW_URL="http://116.198.67.18:31273"
NS="llm-d-precise-prefix-gw"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "=== 验证：Header 修改（添加响应头）==="
echo ""
echo "▶ Step 1: 创建 Header Modifier Policy"
kubectl apply -f "${SCRIPT_DIR}/policy-header-modifier.yaml" 2>&1 | grep -v Warning
sleep 5

echo "▶ Step 2: 发送请求，检查响应头"
RESP_HEADERS=$(curl -s -I --max-time 15 \
  "${GW_URL}/v1/models" 2>/dev/null)
echo "  响应头（关键部分）:"
echo "$RESP_HEADERS" | grep -iE "x-gateway|x-powered|x-custom|content-type|server" | sed 's/^/    /'

if echo "$RESP_HEADERS" | grep -qi "x-gateway-version\|x-powered-by\|x-custom-header"; then
  ok "自定义响应头已添加"
else
  fail "未找到自定义响应头（检查 Policy 字段名是否正确）"
fi

echo ""
echo "清理: kubectl delete agentgatewaypolicy header-modifier-policy -n ${NS}"
