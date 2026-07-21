# install-pool.sh 组件清单

`bash install-pool.sh --pool qwen25-7b` 为 qwen25-7b-instruct 创建一套完整的推理池。
脚本分 3 个步骤，共创建 **15 个 Kubernetes 资源**。

参数来源：`pools/qwen25-7b/pool.env`

```bash
GUIDE_NAME="precise-prefix-cache-routing"
SERVED_MODEL="qwen25-7b-instruct"
MODEL_PATH_RAW="/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct"
MODEL_CACHE="/root/models"
NAMESPACE="llm-d-precise-prefix-gw"
```

---

## 步骤 1 — Deploy Render（Tokenizer）Service

Render Service 为 EPP 提供 token 化能力。EPP 在计算精准前缀哈希时，需要把 prompt 文本转成
token ID 序列，转换工作由 `vllm launch render`（CPU 模式）承担，不占用 GPU。

### 创建的资源

#### Deployment：`precise-prefix-cache-routing-render`

| 字段 | 值 |
|------|----|
| 副本数 | 3（独立于 EPP 副本数，可单独扩缩） |
| 镜像 | `docker.io/vllm/vllm-openai-cpu:v0.23.0` |
| 启动命令 | `vllm launch render <model-path> --port=8000 --served-model-name=qwen25-7b-instruct` |
| CPU | request: 1 核，limit: 4 核 |
| 内存 | request: 4Gi，limit: 12Gi |
| GPU | 无（CPU 模式） |
| 挂载 | hostPath `/root/models` → `/root/models`（读取分词器文件） |

**为什么要 3 副本：** EPP 有 2 个副本，每次收到请求都要调用 render 服务进行 tokenization，3 副本保证并发吞吐不成为瓶颈。

#### Service：`precise-prefix-cache-routing-render`

| 字段 | 值 |
|------|----|
| 类型 | ClusterIP |
| 端口 | 8000（HTTP） |
| Selector | `app.kubernetes.io/component: vllm-render` + `app.kubernetes.io/part-of: precise-prefix-cache-routing` |

EPP 的 `token-producer` 插件通过 `http://precise-prefix-cache-routing-render:8000` 调用此服务。

---

## 步骤 2 — Deploy Gateway

每个推理池独立一个 Gateway，避免多池之间的 HTTPRoute 规则互相干扰。

#### Gateway：`precise-prefix-cache-routing-gateway`

| 字段 | 值 |
|------|----|
| GatewayClass | `agentgateway` |
| 监听端口 | 80（HTTP） |
| 允许的路由来源 | All namespaces |

agentgateway controller 感知到此 Gateway 后，会创建对应的 Envoy 代理 Pod（NodePort），并为其分配集群可访问的端口。

---

## 步骤 3 — Install EPP + HTTPRoute + InferencePool（Helm）

通过 `helm upgrade --install precise-prefix-cache-routing` 创建以下所有资源：

### RBAC 资源（4 个）

#### ServiceAccount：`precise-prefix-cache-routing-epp`

EPP Pod 运行时使用的身份，用于访问 Kubernetes API。

#### Role：`precise-prefix-cache-routing-epp-leader-election`

| 权限 | 说明 |
|------|------|
| `coordination.k8s.io/leases`: get/list/watch/create/update/patch/delete | EPP 2 副本主动-主动模式的分布式锁 |
| `events`: create/patch | 写入 Kubernetes 事件 |

#### Role：`precise-prefix-cache-routing-epp-non-sa`

| 权限 | 说明 |
|------|------|
| `inference.networking.x-k8s.io/inferencemodelrewrites`: get/watch/list | 监听旧版 InferenceModelRewrite（已废弃） |
| `llm-d.ai/inferencemodelrewrites`: get/watch/list | 监听当前版 InferenceModelRewrite（流量分割规则） |
| `inference.networking.k8s.io/inferencepools`: get/watch/list | 监听 InferencePool 状态 |

#### Role：`precise-prefix-cache-routing-epp-sa`

| 权限 | 说明 |
|------|------|
| `pods`: get/watch/list | EPP 发现模型 Pod，读取 Pod IP 用于 KV 事件订阅和端点管理 |

#### RoleBinding × 3

将上述 3 个 Role 分别绑定到 `precise-prefix-cache-routing-epp` ServiceAccount。

---

### EPP 配置（1 个）

#### ConfigMap：`precise-prefix-cache-routing-epp`

存储 EPP 的插件配置文件，挂载到 EPP Pod 的 `/config/` 目录。包含两个内置配置和一个自定义配置：

| 文件 | 用途 |
|------|------|
| `default-plugins.yaml` | 默认调度插件（queue-scorer、kv-cache-utilization-scorer、prefix-cache-scorer） |
| `payload-agnostic.yaml` | 无法解析请求体时的降级配置（session-affinity + active-request） |
| `precise-prefix-cache-routing-plugins.yaml` | **当前激活的配置**，精准前缀缓存路由专用插件链 |

`precise-prefix-cache-routing-plugins.yaml` 的插件链：

```
token-producer          ← 调用 render 服务，把 prompt 转成 token 序列
endpoint-notification-source ← 通过 ZMQ 订阅每个 vLLM pod 的 KV cache 事件
precise-prefix-cache-producer ← 根据 token 序列计算 block hash，构建前缀索引
prefix-cache-scorer     ← 给各 pod 打分：前缀命中的 block 数越多，分数越高
kv-cache-utilization-scorer ← 给各 pod 打分：KV cache 利用率越低，分数越高
queue-scorer            ← 给各 pod 打分：等待队列越短，分数越高
no-hit-lru-scorer       ← 无缓存命中时，按 LRU 策略选最久未用的 pod
```

调度权重：prefix-cache（3.0） > kv-cache-utilization（2.0） = queue（2.0） = no-hit-lru（2.0）

---

### EPP 主体（1 个）

#### Deployment：`precise-prefix-cache-routing-epp`

| 字段 | 值 |
|------|----|
| 副本数 | 2（主动-主动，leader-election 关闭） |
| 部署策略 | Recreate（保证旧副本先退出，防止两个副本同时持有不同状态） |
| 镜像 | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` |
| CPU | request: 4 核 |
| 内存 | request: 8Gi，limit: 16Gi |
| gRPC 端口 | 9002（接收 Envoy ExtProc 调用） |
| gRPC 健康检查端口 | 9003 |
| Metrics 端口 | 9090（Prometheus） |
| 配置文件 | `--config-file /config/precise-prefix-cache-routing-plugins.yaml` |
| 监听的 InferencePool | `--pool-name precise-prefix-cache-routing` |

启动参数关键项：

```bash
--pool-name precise-prefix-cache-routing
--pool-namespace llm-d-precise-prefix-gw
--pool-group inference.networking.k8s.io   # 新版 GIE group
--ha-enable-leader-election=false          # 主动-主动模式
--v=2                                      # 日志级别
```

**EPP 的工作机制：** Envoy（agentgateway 的数据面）收到请求后，通过 ExtProc gRPC 协议把请求转发给 EPP，EPP 计算出目标 Pod 的 IP:Port，以 `x-gateway-destination-endpoint` header 的形式返回给 Envoy，Envoy 再把请求直接转发到对应 Pod。

#### Service：`precise-prefix-cache-routing-epp`

| 端口 | 名称 | 用途 |
|------|------|------|
| 9002 | `grpc-ext-proc` | Envoy ExtProc 调用入口 |
| 9090 | `http-metrics` | Prometheus 采集端口 |
| 80 → 8081 | `http` | （预留）直接 HTTP 访问 |

---

### 路由资源（2 个）

#### HTTPRoute：`precise-prefix-cache-routing`

| 字段 | 值 |
|------|-----|
| 父 Gateway | `precise-prefix-cache-routing-gateway` |
| 匹配规则 | PathPrefix `/`（接受所有路径） |
| 后端 | `InferencePool/precise-prefix-cache-routing`（port: 不指定，由 InferencePool 管理） |
| 超时 | 0s（不限） |

HTTPRoute 把发往此 Gateway 的所有请求转交给 InferencePool，InferencePool 再调用 EPP 选 Pod。

#### InferencePool：`precise-prefix-cache-routing`

| 字段 | 值 |
|------|-----|
| API | `inference.networking.k8s.io/v1` |
| 目标端口 | 8000（模型 Pod 监听端口） |
| appProtocol | http |
| Pod 选择器 | `llm-d.ai/guide: precise-prefix-cache-routing` |
| EPP 引用 | `precise-prefix-cache-routing-epp:9002` |
| 故障模式 | `FailOpen`（EPP 不可用时随机选 Pod，不拒绝请求） |

`selector.matchLabels` 定义了哪些 Pod 属于这个 Pool。后续 `deploy-model.sh` 部署的 vLLM Pod 打上 `llm-d.ai/guide: precise-prefix-cache-routing` 标签，就会自动被这个 Pool 纳管。

---

## 安装后资源全景

```
namespace: llm-d-precise-prefix-gw
│
├── [步骤 1] Render（Tokenizer）
│   ├── Deployment:  precise-prefix-cache-routing-render  (3副本, CPU vLLM)
│   └── Service:     precise-prefix-cache-routing-render  (ClusterIP :8000)
│
├── [步骤 2] Gateway
│   └── Gateway:     precise-prefix-cache-routing-gateway (agentgateway, :80)
│
└── [步骤 3] EPP + 路由（Helm: precise-prefix-cache-routing）
    ├── RBAC
    │   ├── ServiceAccount: precise-prefix-cache-routing-epp
    │   ├── Role:           precise-prefix-cache-routing-epp-leader-election
    │   ├── Role:           precise-prefix-cache-routing-epp-non-sa
    │   ├── Role:           precise-prefix-cache-routing-epp-sa
    │   ├── RoleBinding:    precise-prefix-cache-routing-epp-leader-election-binding
    │   ├── RoleBinding:    precise-prefix-cache-routing-epp-non-sa
    │   └── RoleBinding:    precise-prefix-cache-routing-epp-sa
    ├── EPP
    │   ├── ConfigMap:   precise-prefix-cache-routing-epp  (插件配置)
    │   ├── Deployment:  precise-prefix-cache-routing-epp  (2副本, EPP)
    │   └── Service:     precise-prefix-cache-routing-epp  (ClusterIP :9002/:9090/:80)
    └── 路由
        ├── HTTPRoute:    precise-prefix-cache-routing      (→ InferencePool)
        └── InferencePool: precise-prefix-cache-routing     (→ EPP :9002)
```

完成后运行 `models/start-qwen25-7b-instruct.sh` 部署模型 Pod，Pod 打上 `llm-d.ai/guide: precise-prefix-cache-routing` 标签后即被 InferencePool 自动纳管。
