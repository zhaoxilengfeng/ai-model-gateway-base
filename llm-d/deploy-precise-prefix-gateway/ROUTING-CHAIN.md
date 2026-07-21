# 路由链路与 InferenceModel 的关系

## 结论

**使用 `InferenceModel` 仍然需要 `AgentgatewayPolicy` + `HTTPRoute`**，两者解决的是不同层面的问题，没有重叠，缺一不可。

---

## 完整请求链路

```
客户端请求 POST /v1/chat/completions
  body: {"model": "qwen25-7b-instruct", ...}
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ AgentgatewayPolicy  (phase: PreRouting)             │ ← 层1：Gateway 入口
│                                                     │
│ 从 request body 读取 "model" 字段                    │
│ → 写入 header:                                      │
│   X-Gateway-Base-Model-Name: qwen25-7b-instruct     │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ HTTPRoute                                           │ ← 层2：跨 Pool 路由
│                                                     │
│ 匹配 header X-Gateway-Base-Model-Name               │
│   == "qwen25-7b-instruct" → InferencePool A         │
│   == "glm-4-9b"           → InferencePool B         │
│   (default)               → InferencePool A         │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ EPP（Endpoint Picker，via Envoy ExtProc）            │ ← 层3：Pool 内调度
│                                                     │
│ 1. 解析 request body → IncomingModelName            │
│ 2. 读 x-llm-d-model-name-rewrite header             │
│    （如有）→ TargetModelName 覆盖                    │
│ 3. 查 InferenceModelRewrite / InferenceModel        │
│    → 按 weight 做流量分割，得出 TargetModelName      │
│ 4. 选具体 pod（KV cache 局部性、负载等）              │
│ 5. 返回 x-gateway-destination-endpoint header       │
│    响应体中把 TargetModelName 还原回 IncomingModelName│
└─────────────────────────────────────────────────────┘
         │
         ▼
    模型 Pod（vLLM / sglang）
```

---

## 各层职责对比

| 层级 | 组件 | 职责 | 能否被 InferenceModel 替代 |
|------|------|------|--------------------------|
| Gateway 入口 | `AgentgatewayPolicy` | 从 body 提取 `model` 字段，写入 header | **不能**，InferenceModel 在 EPP 内部，管不到 Gateway 路由层 |
| 跨 Pool 路由 | `HTTPRoute` | 按 header 把请求送到对应的 `InferencePool` | **不能**，不同模型对应不同 Pool，必须由 HTTPRoute 分发 |
| Pool 内流量分割 | `InferenceModel.targetModels` | Pool 内多 LoRA 版本按 weight 分流 | 与 `InferenceModelRewrite` 二选一 |
| Pool 内优先级 | `InferenceModel.criticality` | 过载时按优先级丢弃低优请求 | 无替代，是 InferenceModel 独有功能 |
| Pool 内 pod 选择 | EPP 调度插件 | KV cache 局部性、负载均衡等 | 与 InferenceModel 无关 |

---

## 为什么 AgentgatewayPolicy 不可省略

HTTPRoute 只能匹配 **header**，无法直接读取 HTTP **body**。

客户端发的 `"model"` 字段在 JSON body 里，不在 header 里。`AgentgatewayPolicy` 承担的唯一职责就是：

```
request body ["model"] → HTTP header [X-Gateway-Base-Model-Name]
```

这一步转换是 HTTPRoute 能做跨 Pool 路由的前提。即使部署了 InferenceModel，这个转换仍然必须发生。

---

## 新增模型时需要改动的位置

| 需改动 | 原因 |
|--------|------|
| `policy-model-routing.yaml` — 映射表加一行 | 否则新模型的 `"model"` 字段无法被提取到 header |
| `httproute-model-routing.yaml` — 加对应 rule | 否则新模型的 header 无法路由到对应 InferencePool |
| 如用 InferenceModel — 新建一个 CR | Pool 内优先级 / LoRA 分流配置 |
| 如用 InferenceModelRewrite — 更新规则 | LoRA 版本流量分割配置 |

`AgentgatewayPolicy` 和 `HTTPRoute` **每次新增模型都要改**，这是当前方案的运维成本所在。

---

## 源码依据

| 结论 | 来源 |
|------|------|
| EPP 从 header `x-llm-d-model-name-rewrite` 读 TargetModelName | [handlers/request.go L55](https://github.com/llm-d/llm-d-router/blob/main/pkg/epp/handlers/request.go#L55) |
| EPP 从 request body 读 IncomingModelName，响应体还原 model 字段 | [handlers/server.go L492-L582](https://github.com/llm-d/llm-d-router/blob/main/pkg/epp/handlers/server.go#L492) |
| `x-llm-d-model-name-rewrite` 的定义（旧别名 `x-gateway-model-name-rewrite`）| [metadata/consts.go L42](https://github.com/llm-d/llm-d-router/blob/main/pkg/epp/metadata/consts.go#L42) |
| EPP 只有 InferenceModelRewrite reconciler，无 InferenceModel reconciler | [controller/inferencemodelrewrite_reconciler.go](https://github.com/llm-d/llm-d-router/blob/main/pkg/epp/controller/inferencemodelrewrite_reconciler.go) |
