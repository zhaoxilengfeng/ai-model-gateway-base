# agentgateway 功能验证

验证 agentgateway v1.3.1 在当前 llm-d 集群上的核心功能。

## 环境信息

| 项目 | 值 |
|------|---|
| agentgateway 版本 | v1.3.1 |
| 入口地址 | http://116.198.67.18:31273 |
| 当前 Gateway | llm-d-inference-gateway（llm-d-precise-prefix-gw） |
| 当前模型 | qwen25-7b-instruct |

## 验证项目

| # | 功能 | 目录 | 状态 |
|---|------|------|------|
| 1 | API Key 认证 | `01-api-key-auth/` | 待验证 |
| 2 | 限流（请求级） | `02-rate-limit-requests/` | 待验证 |
| 3 | 限流（Token 级） | `03-rate-limit-tokens/` | 待验证 |
| 4 | 超时控制 | `04-timeout/` | 待验证 |

## 使用方式

每个子目录包含：
- `*.yaml`：K8s 资源配置
- `verify.sh`：验证脚本（apply → 测试 → 预期结果）

```bash
cd /root/ai-model-gateway-base/agentgateway/tests

# 运行单项验证
bash 01-api-key-auth/verify.sh

# 清理所有测试资源
bash cleanup.sh
```

## 注意事项

- 所有测试资源创建在 `llm-d-precise-prefix-gw` namespace
- 测试完成后执行 `cleanup.sh` 删除测试 Policy/Secret，恢复默认状态
- `AgentgatewayPolicy` 通过 `targetRefs` 绑定到 Gateway 或 HTTPRoute
