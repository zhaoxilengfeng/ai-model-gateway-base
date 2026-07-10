# llm-d Gateway 模式资源全景

本文梳理 `llm-d-gateway` 模式运行时在集群中创建的所有 Kubernetes 资源，帮助快速建立全局认识。

---

## 整体架构与请求路径

```
外部请求
  │
  ▼
NodePort (svc/llm-d-inference-gateway :80 → :32212)
  │
  ▼
agentgateway proxy pod           ← 数据面，处理流量转发
  │  (读取 xDS 配置来自 agentgateway controller)
  ▼
HTTPRoute (quickstart)           ← 路由规则：所有路径 → InferencePool
  │
  ▼
InferencePool (quickstart)       ← 调度层：由 EPP 选择后端
  │  selector: llm-d.ai/guide=optimized-baseline
  ▼
EPP pod (quickstart-epp :9002)   ← Endpoint Picker，智能选择 vLLM 实例
  │  (感知 KV Cache、prefill/decode 负载)
  ▼
vLLM pod (qwen25-7b-instruct :8000)
```

---

## Namespace 分布

| Namespace | 用途 |
|---|---|
| `agentgateway-system` | agentgateway 控制面（controller） |
| `llm-d-gateway` | 数据面 + 推理工作负载 |

---

## 资源清单

### agentgateway-system

#### GatewayClass（集群级）

```
名称: agentgateway
controllerName: agentgateway.dev/agentgateway
状态: Accepted
```

注册 `agentgateway` 这个 Gateway 实现，所有 `gatewayClassName: agentgateway` 的 Gateway 对象由它管理。由 `install.sh` Step 3 的 helm chart 自动创建。

#### Deployment / Pod — agentgateway controller

```
名称: agentgateway
镜像: ghcr.io/agentgateway/controller:v1.3.1
```

控制面进程，职责：
- 监听 GatewayClass / Gateway / HTTPRoute / InferencePool 等对象变化
- 通过 xDS gRPC（:9978）将路由配置下发给数据面 proxy pod
- 管理 agentgateway-system 内 ClusterIP svc（:9978 xDS / :9092 metrics / :9093 health）

#### CRDs（agentgateway 专属）

| CRD | 用途 |
|---|---|
| `agentgatewaybackends.agentgateway.dev` | 自定义后端扩展 |
| `agentgatewayparameters.agentgateway.dev` | Gateway 参数配置 |
| `agentgatewaypolicies.agentgateway.dev` | 流量策略 |

由 `install.sh` Step 2 单独 apply（不随 helm chart 打包，需从 GitHub 手动下载）。

---

### llm-d-gateway

#### Gateway

```yaml
名称: llm-d-inference-gateway
gatewayClassName: agentgateway
listeners:
  - port: 80, protocol: HTTP, allowedRoutes.from: All
状态: Programmed=True, attachedRoutes=1
```

代表一个入口点实例。agentgateway controller 发现此对象后，在 `llm-d-gateway` namespace 中创建对应的 **proxy Deployment + LoadBalancer Service**。

由 `install.sh` Step 6 通过 kustomize 创建：
```bash
kubectl apply -k guides/recipes/gateway/agentgateway -n llm-d-gateway
```

#### Deployment / Pod — agentgateway proxy（数据面）

```
名称: llm-d-inference-gateway
镜像: ghcr.io/agentgateway/agentgateway:v1.3.1
```

**由 agentgateway controller 自动生成**（非手动创建），每个 Gateway 对象对应一个 proxy Deployment。负责实际接收并转发 HTTP 流量。

#### Service — llm-d-inference-gateway

```
类型: LoadBalancer（外部 IP pending，NodePort 可用）
端口: 80 → NodePort 32212
```

暴露 proxy pod，外部通过 `<NodeIP>:32212` 访问。

#### HTTPRoute

```yaml
名称: quickstart
parentRefs:
  - Gateway/llm-d-inference-gateway
rules:
  - matches: path prefix /
    backendRefs:
      - InferencePool/quickstart (weight: 1)
    timeouts:
      request: 300s
```

将所有 `/v1/...` 请求路由到 `InferencePool/quickstart`。由 `install.sh` Step 7 helm 安装时通过 `--set httpRoute.create=true` 创建。

#### InferencePool

```yaml
名称: quickstart
selector:
  matchLabels:
    llm-d.ai/guide: optimized-baseline   # 选中 vLLM pod
targetPorts:
  - number: 8000
endpointPickerRef:
  kind: Service
  name: quickstart-epp
  port: 9002
  failureMode: FailOpen
```

Gateway API Inference Extension（GIE）引入的资源类型，作用：
- 用 label selector 圈定一组 vLLM pod 作为候选后端
- 把请求转发给 EPP（:9002）做智能选择，由 EPP 返回最优 pod IP
- `failureMode: FailOpen`：EPP 故障时退化为随机转发，不中断服务

由 `install.sh` Step 7 helm 创建。

#### Deployment / Pod — quickstart-epp（EPP）

```
名称: quickstart-epp
镜像: ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0
服务: ClusterIP :9002（gRPC，供 InferencePool 调用）/ :9090（metrics）/ :80（HTTP）
```

Endpoint Picker，llm-d 的核心调度组件：
- 通过 label selector（`llm-d.ai/guide=optimized-baseline`）持续感知 vLLM pod 列表
- 收集每个 pod 的 KV Cache 使用率、prefill/decode 负载等指标
- 收到请求时选择最优 pod（最低负载 / KV Cache 命中率最高）
- 将选中的 pod IP 返回给 agentgateway proxy，proxy 直连该 pod

#### Deployment / Pod — vLLM model

```
名称: qwen25-7b-instruct
镜像: vllm/vllm-openai:v0.23.0
标签: llm-d.ai/guide=optimized-baseline, llm-d.ai/model=qwen25-7b-instruct
挂载: hostPath /root/models → /root/models
服务: ClusterIP :8000（OpenAI 兼容 HTTP API）
```

实际执行推理的 GPU 工作负载。通过 label 被 InferencePool selector 和 EPP 发现。

---

## 资源创建来源汇总

| 资源 | 创建方式 | install.sh 步骤 |
|---|---|---|
| GatewayClass `agentgateway` | helm agentgateway chart | Step 3 |
| agentgateway controller Deployment | helm agentgateway chart | Step 3 |
| agentgateway CRDs | kubectl apply --server-side | Step 2 |
| GIE CRDs（InferencePool 等） | kubectl apply --server-side | Step 1 |
| Gateway `llm-d-inference-gateway` | kubectl apply -k (kustomize) | Step 6 |
| agentgateway proxy Deployment | **controller 自动生成** | — |
| Service `llm-d-inference-gateway` | **controller 自动生成** | — |
| HTTPRoute `quickstart` | helm llm-d-router-gateway | Step 7 |
| InferencePool `quickstart` | helm llm-d-router-gateway | Step 7 |
| Deployment `quickstart-epp` | helm llm-d-router-gateway | Step 7 |
| Service `quickstart-epp` | helm llm-d-router-gateway | Step 7 |
| Deployment `qwen25-7b-instruct` | deploy-model.sh | 独立脚本 |
| Service `qwen25-7b-instruct` | deploy-model.sh | 独立脚本 |

---

## 快速状态检查

```bash
# 控制面
kubectl get pods -n agentgateway-system
kubectl get gatewayclass agentgateway

# 数据面 + 工作负载
kubectl get pods,svc -n llm-d-gateway
kubectl get gateway,httproute,inferencepool -n llm-d-gateway

# 端到端测试
bash test-llmd.sh
```
