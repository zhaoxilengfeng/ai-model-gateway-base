# 多 InferencePool + HTTPRoute 分流配置

## 场景

在同一个 Gateway 下，对同一模型同时运行两种路由策略：
- **精准前缀路由**：适合有大量重复前缀的请求（RAG、固定 system prompt）
- **负载感知路由**：适合随机请求，按 KV cache 利用率和队列深度均衡负载

通过请求 Header `x-routing-strategy` 区分，客户端保持标准 OpenAI 路径不变。

---

## 部署结构

```
                    Gateway: llm-d-inference-gateway
                              │
              ┌───────────────┴───────────────┐
              │                               │
     HTTPRoute（header match）          HTTPRoute（default）
     x-routing-strategy: precise        path: /
              │                               │
     InferencePool: pool-precise       InferencePool: pool-load-aware
     EPP: precise-prefix-epp           EPP: load-aware-epp
              │                               │
     vLLM pods（共享，同一批节点）     vLLM pods（共享，同一批节点）
```

两个 InferencePool 通过不同的 pod label selector 区分（或共用同一批 pod，label 相同）。

---

## 配置文件

### 1. InferencePool A — 精准前缀路由

```yaml
# pool-precise-prefix.yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: pool-precise-prefix
  namespace: llm-d-gateway
spec:
  appProtocol: http
  selector:
    matchLabels:
      llm-d.ai/guide: optimized-baseline   # 与负载感知 pool 共用同一批 pod
  targetPorts:
  - number: 8000
  endpointPickerRef:
    kind: Service
    name: precise-prefix-epp              # 绑定精准前缀路由的 EPP
    port:
      number: 9002
    failureMode: FailOpen
```

精准前缀路由 EPP 的 ConfigMap（关键配置）：

```yaml
precise-prefix-routing-plugins.yaml: |
  apiVersion: llm-d.ai/v1alpha1
  kind: EndpointPickerConfig
  plugins:
    - type: token-producer
      parameters:
        modelName: qwen25-7b-instruct
        vllm:
          url: "http://precise-render:8000"
    - type: endpoint-notification-source
    - type: precise-prefix-cache-producer
      parameters:
        tokenProcessorConfig:
          blockSize: 64
        kvEventsConfig:
          topicFilter: "kv@"
          concurrency: 8
          discoverPods: true
          podDiscoveryConfig:
            socketPort: 5556
    - type: prefix-cache-scorer
      parameters:
        prefixMatchInfoProducerName: precise-prefix-cache-producer
    - type: kv-cache-utilization-scorer
    - type: queue-scorer
    - type: no-hit-lru-scorer
      parameters:
        prefixMatchInfoProducerName: precise-prefix-cache-producer
  schedulingProfiles:
    - name: default
      plugins:
        - pluginRef: kv-cache-utilization-scorer
          weight: 2.0
        - pluginRef: queue-scorer
          weight: 2.0
        - pluginRef: prefix-cache-scorer
          weight: 3.0
        - pluginRef: no-hit-lru-scorer
          weight: 2.0
```

### 2. InferencePool B — 负载感知路由

```yaml
# pool-load-aware.yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: pool-load-aware
  namespace: llm-d-gateway
spec:
  appProtocol: http
  selector:
    matchLabels:
      llm-d.ai/guide: optimized-baseline
  targetPorts:
  - number: 8000
  endpointPickerRef:
    kind: Service
    name: load-aware-epp                  # 绑定负载感知的 EPP
    port:
      number: 9002
    failureMode: FailOpen
```

负载感知 EPP ConfigMap（去掉精准前缀组件）：

```yaml
load-aware-plugins.yaml: |
  apiVersion: llm-d.ai/v1alpha1
  kind: EndpointPickerConfig
  plugins:
    - type: kv-cache-utilization-scorer
    - type: queue-scorer
  schedulingProfiles:
    - name: default
      plugins:
        - pluginRef: kv-cache-utilization-scorer
          weight: 2.0
        - pluginRef: queue-scorer
          weight: 2.0
```

### 3. HTTPRoute — Header 分流

```yaml
# httproute-multi-strategy.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-d-multi-strategy
  namespace: llm-d-gateway
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: llm-d-inference-gateway

  rules:
  # 规则1：带 header 的走精准前缀路由
  - matches:
    - headers:
      - name: x-routing-strategy
        value: precise-prefix
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: pool-precise-prefix
      weight: 1
    timeouts:
      request: 300s

  # 规则2：默认走负载感知路由
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: pool-load-aware
      weight: 1
    timeouts:
      request: 300s
```

---

## 客户端使用

```bash
GATEWAY="http://<node-ip>:<node-port>"
MODEL="qwen25-7b-instruct"

# 使用精准前缀路由（适合 RAG、固定 system prompt）
curl ${GATEWAY}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'x-routing-strategy: precise-prefix' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"...\"}]}"

# 使用负载感知路由（默认，适合随机请求）
curl ${GATEWAY}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"...\"}]}"
```

---

## 注意事项

### EPP 与 InferencePool 一一对应

每个 InferencePool 只能绑定一个 EPP Service。两个 pool 需要部署两个独立的 EPP Deployment + Service。

### 精准前缀路由 EPP 的启动顺序

精准前缀路由 EPP 必须在 vLLM pod 之后启动，否则 pod-discovery 无法建立 ZMQ 订阅。vLLM pod 重启后也需要重启 EPP：

```bash
kubectl rollout restart deployment/precise-prefix-epp -n llm-d-gateway
```

### render service 仅精准前缀路由需要

负载感知路由不需要 render service（无 token-producer 插件）。render service 的 `--served-model-name` 必须与 EPP `token-producer.modelName` 一致。

### vLLM 配置差异

精准前缀路由要求 vLLM 额外参数：

```bash
--block-size=64          # 必须与 EPP blockSize=64 一致
--kv-events-config '{"enable_kv_cache_events":true,"publisher":"zmq","endpoint":"tcp://*:5556","topic":"kv@$(POD_IP):8000@<model>"}'
```

负载感知路由无需上述参数，标准 `--enable-prefix-caching` 即可。
