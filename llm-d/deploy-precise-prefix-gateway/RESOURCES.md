# 精准前缀缓存路由 Gateway 模式部署详解

本文介绍 `deploy-precise-prefix-gateway` 模式下各服务的职责、配置要点及相互关系。该模式在精准前缀路由的基础上，以 agentgateway 作为数据面 proxy 对外暴露服务，适合需要通过外部 NodePort 访问的生产场景。

---

## 整体架构与请求路径

```
外部客户端
  │
  ▼
NodePort :31889  (svc/llm-d-inference-gateway，LoadBalancer 类型)
  │
  ▼
agentgateway proxy pod           ← 数据面，agentgateway controller 自动创建
  │  接收 HTTP 请求，查询 xDS 路由配置
  ▼
HTTPRoute/precise-prefix-cache-routing
  │  path prefix / → InferencePool/precise-prefix-cache-routing
  ▼
InferencePool/precise-prefix-cache-routing
  │  selector: llm-d.ai/guide=precise-prefix-cache-routing
  │  endpointPickerRef → svc/precise-prefix-cache-routing-epp:9002
  ▼
EPP pod × 2（active-active HA）
  │  ① token-producer：调用 render service 将 prompt tokenize
  │  ② precise-prefix-cache-producer：按 block hash 查索引，选出缓存命中率最高的 pod
  │  ③ 其他 scorer：kv-cache-util × 2、queue × 2、no-hit-lru × 2 加权
  │
  ├── ZMQ SUB → vLLM pod A :5556（实时 KV 块事件）
  └── ZMQ SUB → vLLM pod B :5556（实时 KV 块事件）
  ▼
render service（tokenize）  ←  EPP token-producer 调用
  │  vllm launch render，仅加载 tokenizer，不做推理，不占 GPU
  ▼
vLLM pod（选中的那个）
  │  --block-size=64，--kv-events-config ZMQ，--enable-prefix-caching
  ▼
GPU 推理
```

---

## Namespace 分布

| Namespace | 用途 |
|---|---|
| `agentgateway-system` | agentgateway 控制面（controller）|
| `llm-d-precise-prefix-gw` | 数据面 proxy + EPP + render + vLLM |

---

## 集群级资源

### GatewayClass

```
名称: agentgateway
controllerName: agentgateway.dev/agentgateway
状态: Accepted=True
```

注册 agentgateway 实现，所有 `gatewayClassName: agentgateway` 的 Gateway 对象均由其控制面管理。由 `helm agentgateway` chart 创建（Step 3），在整个集群范围生效，多个 namespace 可复用同一 GatewayClass。

---

## Namespace: agentgateway-system

### agentgateway controller

| 属性 | 值 |
|---|---|
| Pod | `agentgateway-57f54c856-72l79` |
| 节点 | host-000-004（10.244.117.134）|
| 镜像 | `cr.agentgateway.dev/controller:v1.3.1` |
| Service | ClusterIP 10.97.196.39，端口 9978（xDS gRPC）/ 9093（health）/ 9092（metrics）|

**职责**：
- 监听集群中 GatewayClass / Gateway / HTTPRoute / InferencePool 资源变化
- 通过 xDS gRPC（:9978，TLS）将路由配置实时下发给数据面 proxy pod
- 发现 Gateway 对象时，在对应 namespace **自动创建** proxy Deployment + Service

---

## Namespace: llm-d-precise-prefix-gw

### 1. Gateway / agentgateway proxy（数据面入口）

**Gateway 资源**（由 kustomize 创建，install.sh Step 7）：

```yaml
名称: llm-d-inference-gateway
gatewayClassName: agentgateway
listeners:
  - port: 80, protocol: HTTP, allowedRoutes.from: All
状态: Programmed=True, attachedRoutes=1
```

agentgateway controller 发现此对象后，在本 namespace **自动生成**：

**agentgateway proxy Deployment / Pod**：

| 属性 | 值 |
|---|---|
| Pod | `llm-d-inference-gateway-57bc95d559-xb2wq` |
| 节点 | host-000-005（10.244.41.187）|
| 镜像 | `cr.agentgateway.dev/agentgateway:v1.3.1` |

**Service / 对外入口**：

| 属性 | 值 |
|---|---|
| 名称 | `llm-d-inference-gateway` |
| 类型 | LoadBalancer（外部 IP pending，NodePort 可用）|
| ClusterIP | 10.111.96.40 |
| 端口 | **80:31889/TCP**（NodePort 对外暴露）|

外部访问地址：`http://<任意节点IP>:31889`

---

### 2. HTTPRoute

```yaml
名称: precise-prefix-cache-routing
parentRefs:
  - Gateway/llm-d-inference-gateway
rules:
  - matches: path prefix /      # 匹配所有路径
    backendRefs:
      - kind: InferencePool
        name: precise-prefix-cache-routing
    timeouts:
      request: 0s               # 0s = 使用 Gateway 的最大超时
创建方式: helm llm-d-router-gateway（Step 8，--set httpRoute.create=true）
```

将所有进入 Gateway 的请求转发到 InferencePool。

---

### 3. InferencePool

```yaml
名称: precise-prefix-cache-routing
appProtocol: http
selector:
  matchLabels:
    llm-d.ai/guide: precise-prefix-cache-routing   # 选中 vLLM pod
targetPorts:
  - number: 8000
endpointPickerRef:
  kind: Service
  name: precise-prefix-cache-routing-epp
  port: 9002                                       # 调用 EPP gRPC 接口
  failureMode: FailOpen                            # EPP 故障时随机转发，不中断服务
创建方式: helm llm-d-router-gateway（Step 8）
```

GIE（Gateway API Inference Extension）资源，连接路由层与调度层。proxy 收到请求后调用 EPP 的 gRPC 接口（:9002）获取目标 pod IP，再直连该 pod 的 :8000。

---

### 4. EPP（Endpoint Picker）

**精准前缀路由的核心**，负责根据 KV 块哈希索引选择缓存命中率最高的 vLLM pod。

| 属性 | 值 |
|---|---|
| Pod × 2 | `*-crsp9`（host-000-002）/ `*-h6flg`（host-000-005）|
| 镜像 | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` |
| 副本数 | 2（active-active HA，两个副本各自独立订阅所有 vLLM pod 的 ZMQ）|

**Service**：

| 端口 | 用途 |
|---|---|
| :9002（gRPC）| InferencePool 调用，EPP 返回目标 pod IP |
| :9090（HTTP）| Prometheus metrics |
| :80（HTTP）| ⚠️ Gateway 模式下不可用（无 Envoy sidecar），仅 Standalone 模式使用 |

**插件配置**（`precise-prefix-cache-routing-plugins.yaml`）：

```yaml
plugins:
  # Step 1：tokenize prompt
  - type: token-producer
    parameters:
      modelName: qwen25-7b-instruct      # 必须与 render --served-model-name 一致
      vllm:
        url: "http://precise-prefix-cache-routing-render:8000"

  # Step 2：订阅 vLLM KV 块事件（ZMQ）
  - type: endpoint-notification-source
  - type: precise-prefix-cache-producer
    parameters:
      tokenProcessorConfig:
        blockSize: 64                    # 必须与 vLLM --block-size=64 一致
      kvEventsConfig:
        topicFilter: "kv@"              # 匹配 vLLM 发布的 topic 前缀
        discoverPods: true              # 自动发现 pod，扩容无需重启 EPP
        podDiscoveryConfig:
          socketPort: 5556

  # Step 3：评分插件（加权）
  - type: prefix-cache-scorer           # 精准前缀命中分（权重 3，最高）
    parameters:
      prefixMatchInfoProducerName: precise-prefix-cache-producer
  - type: kv-cache-utilization-scorer   # KV cache 利用率（权重 2）
  - type: queue-scorer                  # 请求队列深度（权重 2）
  - type: no-hit-lru-scorer             # 无命中时 LRU 策略（权重 2）

schedulingProfiles:
  - name: default
    plugins:
      - {pluginRef: kv-cache-utilization-scorer, weight: 2.0}
      - {pluginRef: queue-scorer,                weight: 2.0}
      - {pluginRef: prefix-cache-scorer,         weight: 3.0}
      - {pluginRef: no-hit-lru-scorer,           weight: 2.0}
```

**路由决策过程**：
1. 收到请求，`token-producer` 调用 render service 将 prompt tokenize
2. 将 token 序列按 block-size=64 切分为块，计算每块的 SHA256 哈希
3. 在 KV 块索引中查找每个候选 pod 的哈希命中数，计算 prefix-cache 分数
4. 结合 kv-util、queue、lru 分数加权，选出得分最高的 pod
5. 将该 pod 的 IP 返回给 agentgateway proxy，proxy 直连该 pod :8000

**ZMQ 订阅行为**（重要运维知识）：

| 操作 | EPP 行为 |
|---|---|
| `kubectl scale` 扩容新 pod | ✅ 自动发现，自动建立 ZMQ 连接 |
| `kubectl delete pod`（Deployment 重建）| ✅ DELETE+ADD 事件，自动重连 |
| `kubectl rollout restart` vLLM | ❌ ZMQ 断开，需重启 EPP |

---

### 5. render Service（tokenizer）

专门为 EPP 的 `token-producer` 插件提供 tokenize 服务，**不做推理、不占 GPU**。

| 属性 | 值 |
|---|---|
| Pod | `*-2cmbd`（host-000-004，10.244.117.135）|
| 镜像 | `docker.io/vllm/vllm-openai-cpu:v0.23.0`（CPU-only）|
| 启动命令 | `vllm launch render <snapshot-path> --served-model-name=qwen25-7b-instruct` |
| Service ClusterIP | 10.101.160.128:8000 |

**关键约束**：
- 模型路径必须指向**本地 snapshot 绝对路径**，设置 `HF_HUB_OFFLINE=1`，否则会尝试联网下载 tokenizer 失败
- `--served-model-name` 必须与 EPP `token-producer.modelName` 和 vLLM `--served-model-name` **三处完全一致**

---

### 6. vLLM 模型服务（推理后端）

实际执行 GPU 推理的工作负载，同时承担 KV 块事件发布者角色。

| 属性 | 值 |
|---|---|
| Pod × 2 | `*-bpnzw`（host-000-004）/ `*-qpmgr`（host-000-002）|
| 镜像 | `vllm/vllm-openai:v0.23.0` |
| GPU | 每个 pod 独占 1 张 |

**关键启动参数**：

```bash
--served-model-name=qwen25-7b-instruct  # 与 render、EPP 三处一致
--block-size=64                          # 必须与 EPP blockSize=64 完全一致
--enable-prefix-caching                  # 开启 vLLM 内部前缀缓存
--kv-events-config '{
  "enable_kv_cache_events": true,
  "publisher": "zmq",
  "endpoint": "tcp://*:5556",           # ZMQ PUB，EPP 逐个订阅
  "topic": "kv@<pod-ip>:8000@qwen25-7b-instruct"  # topic 含 pod IP 和模型名
}'
```

**Service 端口**：

| 端口 | 用途 |
|---|---|
| :8000（HTTP）| OpenAI 兼容推理 API |
| :5556（TCP）| ZMQ PUB，发布 KV 块事件给 EPP |

**vLLM KV 事件格式**（ZMQ 3 帧 msgpack）：

```
frame[0]: topic = "kv@10.244.117.136:8000@qwen25-7b-instruct"
frame[1]: sequence number
frame[2]: msgpack payload = {event_type: "BlockStored", block_hash: ..., slot: ...}
```

EPP 订阅后，将 block_hash 存入倒排索引，用于后续精准评分。

---

## 资源创建来源汇总

| 资源 | 创建方式 | install.sh 步骤 |
|---|---|---|
| GIE CRDs | `kubectl apply --server-side` | Step 1 |
| agentgateway CRDs | `kubectl apply --server-side` | Step 2 |
| agentgateway controller Deployment/Service | helm agentgateway | Step 3 |
| GatewayClass `agentgateway` | helm agentgateway | Step 3 |
| Namespace `llm-d-precise-prefix-gw` | kubectl create | Step 4 |
| Secret `llm-d-hf-token` | kubectl create | Step 5 |
| render Deployment + Service | kubectl apply（内联 YAML）| Step 6 |
| Gateway `llm-d-inference-gateway` | kubectl apply -k（kustomize）| Step 7 |
| **agentgateway proxy Deployment + Service** | **controller 自动生成** | — |
| HTTPRoute / InferencePool / EPP | helm llm-d-router-gateway | Step 8 |
| vLLM Deployment + Service | deploy-model.sh | 独立脚本 |

---

## 快速状态检查

```bash
# 控制面
kubectl get pods -n agentgateway-system
kubectl get gatewayclass agentgateway

# 数据面 + 工作负载
kubectl get pods,svc -n llm-d-precise-prefix-gw -o wide
kubectl get gateway,httproute,inferencepool -n llm-d-precise-prefix-gw

# EPP ZMQ 连接
EPP_POD=$(kubectl get pods -n llm-d-precise-prefix-gw | grep epp | grep Running | head -1 | awk '{print $1}')
kubectl logs $EPP_POD -n llm-d-precise-prefix-gw -c epp | grep "Connected subscriber socket"

# 端到端验证（含精准路由集中性测试）
bash verify-precise-prefix.sh

# 路由策略对比（精准 vs 随机）
bash /root/ai-model-gateway-base/llm-d/deploy-precise-prefix/test-routing-comparison.sh \
  -n llm-d-precise-prefix-gw
```

---

## 推理池设计指南：一个池 vs 多个池

### 什么时候用一个推理池

满足以下**全部**条件，多个模型部署可以共享同一个 InferencePool：

| 条件 | 原因 |
|------|------|
| **served-model-name 相同** | EPP token-producer 只配一个 modelName，池内所有 pod 必须服务同一模型名 |
| **tokenizer 完全相同** | render service 用 tokenizer 计算 prefix hash，不同 tokenizer 哈希结果不同，路由会混乱 |
| **block-size 相同** | EPP prefix 索引依赖 block-size 对齐，不同值导致哈希不匹配 |
| **KV events 格式兼容** | EPP 只能配一种 engineType（vllm/sglang），混用两种框架时另一种 KV events 无法正确解析 |

**典型可共池场景**：同一模型的 vLLM 版和 sglang 版（served-model-name 相同、tokenizer 相同、block-size 相同）。

---

### 什么时候用多个推理池

满足以下**任一**条件，必须创建独立的推理池：

| 场景 | 原因 |
|------|------|
| **不同模型**（如 qwen vs GLM-4-9B）| served-model-name 不同，tokenizer 不同，HTTPRoute 需要按模型名路由 |
| **不同 tokenizer** | prefix hash 计算错乱，路由会打到错误 pod |
| **独立 SLA 需求** | 对不同模型需分别限流、独立监控、单独扩缩容 |
| **框架 KV events 格式不兼容** | vLLM 和 sglang 混跑，EPP 无法同时正确解析两种格式 |

---

### 新增一个推理池需要部署哪些组件

与现有池 `precise-prefix-cache-routing` 完全独立，每个新池需要完整的一套组件：

| 组件 | 说明 | 是否可复用现有 |
|------|------|--------------|
| **模型 Deployment + Service** | 实际推理 pod，需配置 `--kv-events-config` ZMQ 和新的 label | ❌ 独立部署 |
| **InferencePool** | 通过新 label selector 圈定本池的 pod | ❌ 每个池独立 |
| **EPP Deployment + Service** | 独立的路由决策服务，token-producer 配置新模型的 modelName | ❌ 每个池独立 |
| **EPP ConfigMap** | 插件配置，token-producer 指向新 render 服务 URL | ❌ 每个池独立 |
| **render Service** | CPU-only tokenize 服务，加载新模型的 tokenizer | ❌ 每个池独立（tokenizer 不同） |
| **HTTPRoute 新规则** | 按模型名或 path 路由到新 InferencePool | ❌ 在现有 HTTPRoute 追加，或新建 HTTPRoute |
| **Gateway** | 数据面入口 | ✅ **可复用**现有 `llm-d-inference-gateway` |
| **agentgateway controller** | 控制面 | ✅ **可复用**（集群全局共享） |
| **GatewayClass** | agentgateway 注册 | ✅ **可复用**（集群全局共享） |

**关键三处保持一致**（同一个池内）：

```
render service --served-model-name
      ↕ 必须完全一致
EPP token-producer.modelName
      ↕ 必须完全一致
vLLM --served-model-name
```

#### 以 GLM-4-9B 为例，新增第二个池需要的操作

```bash
# 1. 部署 GLM-4-9B 模型（Deployment + Service，label 用新 guide 名）
bash deploy-glm4-9b.sh   # 使用新 label: llm-d.ai/guide: glm-4-9b-pool

# 2. 部署 render service（加载 GLM-4-9B tokenizer）
kubectl apply -f render-glm4.yaml

# 3. 部署 EPP（独立副本，ConfigMap 中 modelName: glm-4-9b，render URL 指向新 render）
kubectl apply -f epp-glm4.yaml

# 4. 创建 InferencePool（selector: llm-d.ai/guide: glm-4-9b-pool）
kubectl apply -f inferencepool-glm4.yaml

# 5. 在 HTTPRoute 追加路由规则（按 header/path 区分，或通过不同端口/路径）
kubectl apply -f httproute-with-glm4.yaml
```

#### 路由分流方案

同一个 Gateway 下两个模型的分流，推荐按请求体里的 `model` 字段路由：

```yaml
# HTTPRoute 示例（agentgateway 支持按 header 路由）
rules:
  - matches:
      - headers:
          - name: x-model-name
            value: qwen25-7b-instruct
    backendRefs:
      - kind: InferencePool
        name: precise-prefix-cache-routing
  - matches:
      - headers:
          - name: x-model-name
            value: glm-4-9b
    backendRefs:
      - kind: InferencePool
        name: glm-4-9b-pool
```

> **注意**：agentgateway 当前版本（v1.3.1）不原生解析 OpenAI `model` 字段做路由，
> 需要客户端在 header 里额外携带 `x-model-name`，或通过不同路径（`/v1/qwen/` vs `/v1/glm/`）区分。
> 后续版本可能支持按 request body 中的 `model` 字段直接路由。

