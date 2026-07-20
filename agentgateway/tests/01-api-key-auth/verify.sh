#!/usr/bin/env bash
# 01-api-key-auth/verify.sh — 验证 agentgateway API Key 认证功能
#
# 测试内容：
#   1. 创建 API Key Secret
#   2. 创建 AgentgatewayPolicy 绑定到 HTTPRoute，开启 API Key 认证（Strict 模式）
#   3. 无 Key 请求 → 应返回 401
#   4. 错误 Key 请求 → 应返回 401/403
#   5. 正确 Key 请求 → 应正常推理
#   6. 清理资源

set -euo pipefail

NS="llm-d-precise-prefix-gw"
GW_URL="http://116.198.67.18:31273"
MODEL="qwen25-7b-instruct"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

echo ""
echo "=== 验证：API Key 认证 ==="
echo "    Gateway: $GW_URL"
echo "    Namespace: $NS"
echo ""

# 1. 创建 API Key Secret
echo "▶ Step 1: 创建 API Key Secret"
kubectl apply -f "${SCRIPT_DIR}/api-key-secret.yaml" 2>&1 | grep -v 'Warning'
sleep 2

# 2. 创建 AgentgatewayPolicy
echo "▶ Step 2: 创建 AgentgatewayPolicy（Strict 模式）"
kubectl apply -f "${SCRIPT_DIR}/policy-api-key.yaml" 2>&1 | grep -v 'Warning'
sleep 5

# 3. 无 Key 请求 → 期望 401/403
echo "▶ Step 3: 无 API Key 请求（期望 401/403）"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
if [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
  ok "无 Key → HTTP $STATUS（认证拦截正常）"
else
  fail "无 Key → HTTP $STATUS（期望 401/403）"
fi

# 4. 错误 Key 请求 → 期望 401/403
echo "▶ Step 4: 错误 API Key 请求（期望 401/403）"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wrong-key-12345" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
if [[ "$STATUS" == "401" || "$STATUS" == "403" ]]; then
  ok "错误 Key → HTTP $STATUS（认证拦截正常）"
else
  fail "错误 Key → HTTP $STATUS（期望 401/403）"
fi

# 5. 正确 Key 请求 → 期望 200
echo "▶ Step 5: 正确 API Key 请求（期望 200）"
RESP=$(curl -s --max-time 30 \
  "${GW_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer test-api-key-001" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}")
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null | grep -q .; then
  ok "正确 Key → 推理成功"
  echo "    回复: $(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null)"
else
  fail "正确 Key → 推理失败: $(echo "$RESP" | head -c 200)"
fi

echo ""
echo "=== API Key 认证验证完成 ==="
echo "清理资源请运行: bash ${SCRIPT_DIR}/../cleanup.sh api-key"
