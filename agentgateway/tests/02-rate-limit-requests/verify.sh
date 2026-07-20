#!/usr/bin/env bash
# 02-rate-limit-requests/verify.sh — 验证请求级限流（本地限流，10 req/min）
#
# 测试内容：
#   1. 创建 AgentgatewayPolicy：限制 HTTPRoute 每分钟最多 5 个请求
#   2. 连续发送 8 个请求
#   3. 前 5 个应返回 200，后 3 个应返回 429

set -euo pipefail

NS="llm-d-precise-prefix-gw"
GW_URL="http://116.198.67.18:31273"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} $*"; }

echo ""
echo "=== 验证：请求级限流（5 req/min）==="
echo "    Gateway: $GW_URL"
echo ""

# 1. 创建限流 Policy
echo "▶ Step 1: 创建限流 Policy（5 req/min）"
kubectl apply -f "${SCRIPT_DIR}/policy-rate-limit-requests.yaml" 2>&1 | grep -v 'Warning'
echo "    等待 Policy 生效（10s）..."
sleep 10

# 2. 发送 8 个请求，记录状态码
echo "▶ Step 2: 连续发送 8 个请求"
PASS=0; RATE_LIMITED=0; OTHER=0
for i in $(seq 1 8); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    "${GW_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5,\"stream\":false}")
  echo "    req #$i → HTTP $STATUS"
  case "$STATUS" in
    200) PASS=$((PASS+1)) ;;
    429) RATE_LIMITED=$((RATE_LIMITED+1)) ;;
    *)   OTHER=$((OTHER+1)) ;;
  esac
  sleep 0.5
done

echo ""
echo "  结果: 成功=$PASS  限流(429)=$RATE_LIMITED  其他=$OTHER"
if [[ $RATE_LIMITED -gt 0 ]]; then
  ok "限流生效，$RATE_LIMITED 个请求被拒绝（429）"
else
  fail "未触发限流，检查 Policy 是否正确绑定"
fi

echo ""
echo "=== 请求级限流验证完成 ==="
echo "清理资源请运行: kubectl delete agentgatewaypolicy rate-limit-requests-policy -n ${NS}"
