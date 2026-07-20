# agentgateway 功能验证

验证 agentgateway v1.3.1 在当前 llm-d 集群上的核心功能。

## 环境信息

| 项目 | 值 |
|------|---|
| agentgateway 版本 | v1.3.1 |
| 入口地址 | http://116.198.67.18:31273 |
| Gateway | llm-d-inference-gateway（llm-d-precise-prefix-gw） |
| HTTPRoute | precise-prefix-cache-routing |
| 当前模型 | qwen25-7b-instruct |

## 验证项目

| # | 功能 | 目录 | 结果 |
|---|------|------|------|
| 1 | API Key 认证（Strict/Permissive 模式） | `01-api-key-auth/` | ✅ 通过 |
| 2 | 限流（请求级，5 req/min + burst） | `02-rate-limit-requests/` | ✅ 通过 |
| 3 | 限流（Token 级，1000 token/min） | `03-rate-limit-tokens/` | 待验证 |
| 4 | 超时控制（request timeout）| `04-timeout/` | 待验证 |
| 5 | HTTP Basic 认证 | `05-basic-auth/` | 待验证 |
| 6 | CORS 跨域策略 | `06-cors/` | 待验证 |
| 7 | 请求/响应 Header 修改 | `07-header-modifier/` | 待验证 |

## 使用方式

```bash
cd /root/ai-model-gateway-base/agentgateway/tests

# 运行单项验证（每次只建议开启一个 Policy，避免互相干扰）
bash 01-api-key-auth/verify.sh
bash 02-rate-limit-requests/verify.sh
bash 03-rate-limit-tokens/verify.sh
bash 04-timeout/verify.sh
bash 05-basic-auth/verify.sh
bash 06-cors/verify.sh
bash 07-header-modifier/verify.sh

# 清理所有测试资源（每次测试后执行）
bash cleanup.sh
```

## 注意事项

- 每次测试前先执行 `cleanup.sh` 确保没有残留 Policy 干扰
- 多个 Policy 同时绑定到同一 HTTPRoute 会合并生效，可能相互影响
- Token 限流基于上一个请求完成后的累计数，对当前进行中的请求不生效
- 超时设置影响流式输出（streaming），需要设置足够长的时间
