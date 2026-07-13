# llm-d 路由策略选择与多策略并存

## 路由策略概览

llm-d EPP 通过 `EndpointPickerConfig` 中的 `schedulingProfiles` 配置路由策略，核心是 **Filter → Score → Pick** 三阶段 pipeline。

### 可用 Scorer 插件

| 插件 | 作用 | 适合场景 |
|---|---|---|
| `prefix-cache-scorer` | 按前缀缓存命中率打分（启发式估算）| 通用前缀缓存感知 |
| `precise-prefix-cache-producer` + `prefix-cache-scorer` | 通过 ZMQ 实时 KV 块事件精准评分 | 高前缀重复率（如 system prompt 固定）|
| `kv-cache-utilization-scorer` | 优先选 KV cache 利用率低的 pod | 防止 KV cache 碎片化 |
| `queue-scorer` | 优先选请求队列短的 pod | 高并发、均匀负载 |
| `no-hit-lru-scorer` | 无缓存命中时按 LRU 策略选 pod | 配合前缀路由使用 |
| `latency-scorer` | 按预测延迟打分（需 Latency Predictor）| SLO 敏感场景 |
| `lora-affinity-scorer` | 优先选已加载对应 LoRA 的 pod | 多 LoRA 模型场景 |

### 三种典型策略对比

| 策略 | 配置 | 适合场景 | 备注 |
|---|---|---|---|
| **optimized-baseline** | queue×2 + kv-util×2 + prefix-cache×3 + lru×2 | 通用生产环境 | 启发式前缀缓存，无需 ZMQ |
| **precise-prefix-cache-routing** | 同上，但 prefix-cache 改为精准 ZMQ 驱动 | 高前缀重复率（RAG、长 system prompt）| 需 vLLM `--block-size=64` + ZMQ |
| **负载感知（纯）** | queue×2 + kv-util×2 | 每次请求前缀差异大（如开放问答）| 去掉 prefix scorer，避免无效计算 |

---

## 一个集群同时支持多个路由策略

llm-d 支持在同一 Gateway 下并存多个路由策略，有两种方式：

### 方式一：多 InferencePool（推荐）

每个 InferencePool 绑定一个独立的 EPP，各自配置不同的路由策略。在 HTTPRoute 层面按 **Header** 或 **Path** 分流。

```
Gateway
  │
  ├── HTTPRoute（Header: x-routing-strategy=precise）
  │     └── InferencePool A（精准前缀路由 EPP）
  │               └── vLLM pods（带 ZMQ KV 事件）
  │
  └── HTTPRoute（默认，无 header）
        └── InferencePool B（负载感知 EPP）
                  └── vLLM pods
```

**同一批 vLLM pod 也可以被两个 pool 共享**（label selector 相同），路由逻辑不同但后端一致。

### 方式二：单 EPP 多 schedulingProfile（高级）

在同一 EPP 配置多个 `schedulingProfiles`，配合自定义 `ProfileHandler` 按请求特征选择 profile。

- 内置仅支持 `single-profile-handler`（单 profile）和 `disagg-profile-handler`（P/D 分离专用）
- 其他多 profile 场景需自己实现 `ProfileHandler` 插件，开发成本较高
- **实践建议**：优先用方式一，除非有强烈的资源共享需求

---

## HTTPRoute 分流方式选择

官方文档明确支持 **path match** 和 **header match** 两种，没有强制最佳实践，根据业务场景选择：

### Header match（更常用）

客户端保持标准 OpenAI 路径（`/v1/chat/completions`），通过 header 声明路由偏好：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-d-routes
  namespace: llm-d-gateway
spec:
  parentRefs:
  - name: llm-d-inference-gateway
  rules:
  # 带 header 的走精准前缀路由池
  - matches:
    - headers:
      - name: x-routing-strategy
        value: precise-prefix
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: pool-precise-prefix

  # 默认走负载感知池
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: pool-load-aware
```

客户端使用：

```bash
# 精准前缀路由
curl http://<gateway>/v1/chat/completions \
  -H 'x-routing-strategy: precise-prefix' \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct",...}'

# 默认负载感知路由（无需额外 header）
curl http://<gateway>/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct",...}'
```

**优点**：路径不变，对客户端侵入最小，迁移成本低。

### Path prefix match

适合完全不同的服务入口，如批处理 vs 实时推理：

```yaml
rules:
- matches:
  - path:
      type: PathPrefix
      value: /realtime
  backendRefs:
  - kind: InferencePool
    name: pool-realtime       # 低延迟策略

- matches:
  - path:
      type: PathPrefix
      value: /batch
  backendRefs:
  - kind: InferencePool
    name: pool-batch          # 高吞吐策略
```

**缺点**：改变了 OpenAI 标准 API 路径，客户端需要适配。

### 权重分流（A/B 测试 / 灰度）

同一 HTTPRoute 规则内按权重分流到两个 pool：

```yaml
rules:
- matches:
  - path:
      type: PathPrefix
      value: /
  backendRefs:
  - kind: InferencePool
    name: pool-stable
    weight: 90              # 90% 流量走稳定策略
  - kind: InferencePool
    name: pool-canary
    weight: 10              # 10% 流量走新策略
```

适合在不停服的情况下验证新路由策略的效果。

---

## 选择建议

| 场景 | 推荐方式 |
|---|---|
| RAG / 长 system prompt，前缀高度重复 | 精准前缀路由（precise-prefix-cache-routing）|
| 开放问答，每次请求差异大 | 负载感知（queue + kv-util）|
| 需要同时支持两种策略 | 多 InferencePool + Header match |
| 新策略灰度验证 | 权重分流（weight）|
| 批处理 vs 实时推理分离 | Path prefix match |
| 多 LoRA 适配器 | lora-affinity-scorer |
