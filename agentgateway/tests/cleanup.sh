#!/usr/bin/env bash
# cleanup.sh — 清理所有 agentgateway 测试资源

NS="llm-d-precise-prefix-gw"

echo "=== 清理 agentgateway 测试资源 ==="

kubectl delete agentgatewaypolicy \
  api-key-auth-policy \
  rate-limit-requests-policy \
  rate-limit-tokens-policy \
  timeout-policy \
  basic-auth-policy \
  cors-policy \
  header-modifier-policy \
  -n "$NS" --ignore-not-found 2>&1

kubectl delete secret \
  agentgateway-api-keys \
  basic-auth-users \
  -n "$NS" --ignore-not-found 2>&1

echo "=== 清理完成，已恢复默认配置 ==="
