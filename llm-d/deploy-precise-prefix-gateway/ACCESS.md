# 固安集群组件访问方式

> 集群：guan-cluster（master01: 116.198.67.18:12026，GPU worker: h200-12-3: 11.194.12.3）
> Namespace：`llm-d-precise-prefix-gw`

本文记录集群中各组件的对外访问方式，包括直接访问地址、端口映射和需要隧道的场景。

---

## 一、模型推理 API

### 1.1 agentgateway 统一入口（推荐）

所有模型请求统一走 agentgateway，由 EPP 做智能路由。

| | 值 |
|--|--|
| 地址 | `http://116.198.67.18:31273` |
| 类型 | NodePort（LoadBalancer pending） |
| 协议 | OpenAI 兼容 API |

```bash
# qwen25-7b-instruct（vLLM，精准前缀路由）
curl http://116.198.67.18:31273/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"你好"}],"max_tokens":100}'

# glm-5-2-fp8（sglang，指标路由）
curl http://116.198.67.18:31273/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-5-2-fp8","messages":[{"role":"user","content":"你好"}],"max_tokens":100}'

# 查看已注册模型
curl http://116.198.67.18:31273/v1/models
```

### 1.2 GLM-5.2-FP8 直连 NodePort

绕过 agentgateway，直连 sglang 服务（调试用）。

| | 值 |
|--|--|
| 地址 | `http://116.198.67.18:30001` |
| 类型 | NodePort |

```bash
curl http://116.198.67.18:30001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-5-2-fp8","messages":[{"role":"user","content":"你好"}],"max_tokens":100}'
```

### 1.3 vLLM pod 直连（调试用）

绕过 agentgateway 和 EPP，直连指定 vLLM pod（验证单 pod 行为时使用）。

```bash
# 获取某个 pod IP
kubectl get pod -n llm-d-precise-prefix-gw \
  -l "llm-d.ai/model=qwen25-7b-instruct" -o wide

# 直连推理
curl http://<POD_IP>:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"你好"}],"max_tokens":50}'
```

---

## 二、agentgateway Admin UI

Admin UI 内置于 proxy pod，监听 `localhost:15000`（仅 pod 内部，不绑定 0.0.0.0），**必须通过 kubectl port-forward 访问**。

> 详细排查记录：[agentgateway-ui-troubleshooting.md](../../../model-gateway-research/llm-d/agentgateway-ui-troubleshooting.md)（model-gateway-research 仓库）

### 2.1 在 master01 本地访问

```bash
# 前台运行（Ctrl+C 停止）
bash llm-d/deploy-precise-prefix-gateway/expose-agentgateway-ui.sh portforward

# 访问地址（master01 本地）
curl http://localhost:15000/ui/
```

### 2.2 从本地电脑（Mac/Linux）访问

```bash
# Step 1：在 master01 上后台启动 port-forward
ssh -p 12026 root@116.198.67.18 \
  "bash /root/ai-model-gateway-base/llm-d/deploy-precise-prefix-gateway/expose-agentgateway-ui.sh remote 15000"

# Step 2：本地建立 SSH 隧道（新终端）
ssh -p 12026 -L 15000:127.0.0.1:15000 root@116.198.67.18 -N

# Step 3：浏览器访问
open http://localhost:15000/ui/
```

### 2.3 UI 功能说明

| 功能 | 说明 | 可交互 |
|------|------|--------|
| Listeners | proxy 监听的端口及路由 | 只读 |
| Routes | HTTPRoute 规则与后端 | 只读 |
| Policies | 生效策略列表 | 只读 |
| CEL Playground | 测试 CEL 表达式 | ✅ |

---

## 三、EPP Metrics

EPP 暴露 Prometheus 指标，可查看路由调度决策和 KV cache 命中情况。

| | 值 |
|--|--|
| Service | `precise-prefix-cache-routing-epp:9090`（ClusterIP） |
| 访问方式 | kubectl port-forward |

```bash
# port-forward
kubectl port-forward -n llm-d-precise-prefix-gw \
  svc/precise-prefix-cache-routing-epp 9090:9090

# 查看指标
curl http://localhost:9090/metrics | grep -E "prefix_cache|kv_cache|queue"
```

---

## 四、agentgateway Controller Metrics

| | 值 |
|--|--|
| Service | `agentgateway-system/agentgateway:9092`（ClusterIP） |
| 访问方式 | kubectl port-forward |

```bash
kubectl port-forward -n agentgateway-system \
  svc/agentgateway 9092:9092

curl http://localhost:9092/metrics
```

---

## 五、OpenTelemetry / 链路追踪（待接入）

> 计划接入 OpenTelemetry，接入后在此补充访问方式。

agentgateway 支持 OTLP trace 导出，配置方式：

```yaml
# agentgateway 配置（待补充）
telemetry:
  tracing:
    otlp:
      endpoint: "http://<otel-collector>:4317"
```

相关组件访问方式（接入后补充）：
- Jaeger UI：`http://<node>:<jaeger-nodeport>/`
- OpenTelemetry Collector：`<otel-collector-svc>:4317`（gRPC）/ `:4318`（HTTP）

---

## 六、访问方式速查表

| 组件 | 访问方式 | 地址 | 备注 |
|------|---------|------|------|
| 模型推理（统一入口） | 直接访问 | `http://116.198.67.18:31273` | agentgateway NodePort |
| GLM 直连 | 直接访问 | `http://116.198.67.18:30001` | sglang NodePort |
| agentgateway UI | port-forward | `http://localhost:15000/ui/` | admin 绑定 127.0.0.1 |
| EPP Metrics | port-forward | `http://localhost:9090/metrics` | ClusterIP |
| Controller Metrics | port-forward | `http://localhost:9092/metrics` | ClusterIP |
| OpenTelemetry | 待接入 | — | 计划中 |

---

## 附：通用 port-forward 方式

```bash
# 格式
kubectl port-forward -n <namespace> <resource-type>/<resource-name> <local-port>:<remote-port>

# 后台运行
kubectl port-forward -n llm-d-precise-prefix-gw \
  deployment/llm-d-inference-gateway 15000:15000 &

# 停止所有 port-forward
pkill -f "kubectl port-forward"
```
