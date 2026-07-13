# llm-d Gateway 模式资源全景

本文梳理 `llm-d-gateway` 模式运行时在集群中创建的所有 Kubernetes 资源，帮助快速建立全局认识。

---

## 整体架构与请求路径

```
外部请求
  │
  ▼
NodePort 32212  (svc/llm-d-inference-gateway  80:32212/TCP)
  │
  ▼
agentgateway proxy pod  [10.244.117.176, host-000-004]
  │  cr.agentgateway.dev/agentgateway:v1.3.1
  │  从 agentgateway controller 通过 xDS gRPC(:9978) 获取路由配置
  ▼
HTTPRoute/quickstart
  │  path prefix / → InferencePool/quickstart
  ▼
InferencePool/quickstart
  │  selector: llm-d.ai/guide=optimized-baseline
  │  endpointPickerRef → svc/quickstart-epp:9002
  ▼
EPP pod  [10.244.117.177, host-000-004]
  │  ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0
  │  感知 KV Cache / prefill-decode 负载，选出最优 vLLM pod
  ▼
vLLM pod  [10.244.41.172, host-000-005]
  │  vllm/vllm-openai:v0.23.0
  │  OpenAI 兼容 HTTP API :8000
  ▼
GPU 推理
```

---

## Namespace 分布

| Namespace | 职责 |
|---|---|
| `agentgateway-system` | agentgateway 控制面（controller），管理 GatewayClass 和 xDS 配置下发 |
| `llm-d-gateway` | 数据面 proxy + 推理工作负载（EPP、vLLM）|

---

## 集群级资源

### GatewayClass

| 字段 | 值 |
|---|---|
| 名称 | `agentgateway` |
| controllerName | `agentgateway.dev/agentgateway` |
| 状态 | Accepted=True |
| 创建方式 | helm agentgateway chart（install.sh Step 3）|

注册 agentgateway 实现。所有 `gatewayClassName: agentgateway` 的 Gateway 对象均由其控制面管理。

### CRDs

**Gateway API（GIE，Gateway API Inference Extension）**

| CRD | 用途 |
|---|---|
| `gateways.gateway.networking.k8s.io` | Gateway 入口点定义 |
| `gatewayclasses.gateway.networking.k8s.io` | Gateway 实现注册 |
| `httproutes.gateway.networking.k8s.io` | HTTP 路由规则 |
| `grpcroutes.gateway.networking.k8s.io` | gRPC 路由规则 |
| `referencegrants.gateway.networking.k8s.io` | 跨 namespace 引用授权 |
| `inferencepools.inference.networking.k8s.io` | 推理后端池（GIE v1） |
| `inferencemodels.inference.networking.x-k8s.io` | 推理模型声明（GIE 实验） |
| `inferencepools.inference.networking.x-k8s.io` | 推理后端池（GIE 实验） |

由 install.sh Step 1（`kubectl apply --server-side -f gie-v1.5.0.yaml`）安装。

**agentgateway 专属**

| CRD | 用途 |
|---|---|
| `agentgatewaybackends.agentgateway.dev` | 自定义后端扩展 |
| `agentgatewayparameters.agentgateway.dev` | Gateway 参数配置 |
| `agentgatewaypolicies.agentgateway.dev` | 流量策略 |

由 install.sh Step 2（`kubectl apply --server-side -f agentgateway-crds/`）安装，**不随 helm chart 打包**，需从 GitHub 单独下载。

### ClusterRole / ClusterRoleBinding

| 资源 | 名称 | 用途 |
|---|---|---|
| ClusterRole | `agentgateway-agentgateway-system` | agentgateway controller 读取 Gateway/HTTPRoute/InferencePool 等资源权限 |
| ClusterRoleBinding | `agentgateway-role-agentgateway-system` | 绑定到 `agentgateway-system/agentgateway` ServiceAccount |

---

## Namespace: agentgateway-system

### Pod

| 名称 | 镜像 | 节点 | IP |
|---|---|---|---|
| `agentgateway-57f54c856-w9bl2` | `cr.agentgateway.dev/controller:v1.3.1` | host-000-004 | 10.244.117.175 |

### Deployment

| 名称 | 副本 | 镜像 |
|---|---|---|
| `agentgateway` | 1/1 | `cr.agentgateway.dev/controller:v1.3.1` |

**职责**：
- 监听 GatewayClass / Gateway / HTTPRoute / InferencePool 对象变化
- 将路由配置通过 xDS gRPC 下发给数据面 proxy pod
- 发现 Gateway 对象后，在对应 namespace 自动创建 proxy Deployment + Service

### Service

| 名称 | 类型 | ClusterIP | 端口 |
|---|---|---|---|
| `agentgateway` | ClusterIP | 10.97.7.178 | 9978/TCP（xDS gRPC）, 9093/TCP（health）, 9092/TCP（metrics）|

### ServiceAccount

| 名称 | 说明 |
|---|---|
| `agentgateway` | controller pod 使用，绑定 ClusterRole 读取集群资源 |

### Secret

| 名称 | 类型 | 说明 |
|---|---|---|
| `kgateway-xds-cert` | Opaque | xDS TLS 证书，controller 与 proxy 之间加密通信用 |
| `sh.helm.release.v1.agentgateway.v1` | helm.sh/release.v1 | Helm 发布元数据 |

---

## Namespace: llm-d-gateway

### Pod

| 名称 | 镜像 | 节点 | IP | 说明 |
|---|---|---|---|---|
| `llm-d-inference-gateway-669f9c6466-2n7bh` | `cr.agentgateway.dev/agentgateway:v1.3.1` | host-000-004 | 10.244.117.176 | 数据面 proxy，agentgateway controller 自动创建 |
| `quickstart-epp-798cf686cb-mpjjt` | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` | host-000-004 | 10.244.117.177 | EPP，智能选择 vLLM 后端 |
| `qwen25-7b-instruct-847c7d995-5t9j5` | `vllm/vllm-openai:v0.23.0` | host-000-005 | 10.244.41.172 | vLLM 推理服务 |

### Deployment

| 名称 | 副本 | 镜像 | 创建方式 |
|---|---|---|---|
| `llm-d-inference-gateway` | 1/1 | `cr.agentgateway.dev/agentgateway:v1.3.1` | controller 自动生成（非手动） |
| `quickstart-epp` | 1/1 | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0` | helm llm-d-router-gateway |
| `qwen25-7b-instruct` | 1/1 | `vllm/vllm-openai:v0.23.0` | deploy-model.sh |

### Service

| 名称 | 类型 | ClusterIP | 端口 | Selector |
|---|---|---|---|---|
| `llm-d-inference-gateway` | LoadBalancer | 10.110.10.16 | **80:32212/TCP**（NodePort 对外暴露）| gateway-name=llm-d-inference-gateway |
| `quickstart-epp` | ClusterIP | 10.97.170.239 | 9002/TCP（gRPC，EPP 选路）, 9090/TCP（metrics）, 80/TCP（HTTP）| llm-d-router-gateway=quickstart-epp |
| `qwen25-7b-instruct` | ClusterIP | 10.99.253.105 | 8000/TCP（OpenAI API）| llm-d.ai/guide=optimized-baseline, llm-d.ai/model=qwen25-7b-instruct |

### Gateway

```yaml
名称: llm-d-inference-gateway
gatewayClassName: agentgateway
listeners:
  - name: default
    port: 80
    protocol: HTTP
    allowedRoutes.namespaces.from: All
状态: Accepted=True, Programmed=True, attachedRoutes=1
创建方式: kubectl apply -k guides/recipes/gateway/agentgateway（install.sh Step 6）
```

agentgateway controller 发现此对象后自动创建 proxy Deployment 和 LoadBalancer Service。

### HTTPRoute

```yaml
名称: quickstart
parentRefs:
  - Gateway/llm-d-inference-gateway
rules:
  - matches:
      - path: PathPrefix /        # 匹配所有路径
    backendRefs:
      - kind: InferencePool
        name: quickstart
        weight: 1
    timeouts:
      request: 300s              # 推理超时 5 分钟
状态: Accepted=True, ResolvedRefs=True
创建方式: helm llm-d-router-gateway（install.sh Step 7，--set httpRoute.create=true）
```

### InferencePool

```yaml
名称: quickstart
appProtocol: http
selector:
  matchLabels:
    llm-d.ai/guide: optimized-baseline    # 选中 vLLM pod
targetPorts:
  - number: 8000                           # 转发到 vLLM 端口
endpointPickerRef:
  kind: Service
  name: quickstart-epp
  port: 9002                               # 调用 EPP gRPC 接口选路
  failureMode: FailOpen                    # EPP 故障时退化为随机转发
状态: Accepted=True, ResolvedRefs=True
创建方式: helm llm-d-router-gateway（install.sh Step 7）
```

### ServiceAccount

| 名称 | 说明 |
|---|---|
| `llm-d-inference-gateway` | proxy pod 使用 |
| `quickstart-epp` | EPP pod 使用，绑定 Role 读取 pod/endpoint 资源 |

### Role / RoleBinding

| 名称 | 类型 | 说明 |
|---|---|---|
| `quickstart-epp-sa` | Role | EPP ServiceAccount 权限：读取 pods、endpoints、endpointslices |
| `quickstart-epp-non-sa` | Role | 非 SA 访问补充权限 |
| `quickstart-epp-sa` | RoleBinding | 绑定 quickstart-epp ServiceAccount |
| `quickstart-epp-non-sa` | RoleBinding | 绑定补充权限 |

### ConfigMap

| 名称 | 说明 |
|---|---|
| `llm-d-inference-gateway` | proxy pod 配置文件（由 controller 生成） |
| `llm-d-inference-gateway-xds-ca` | xDS TLS CA 证书（proxy 验证 controller 身份） |
| `quickstart-epp` | EPP 配置（模型名、调度策略等） |

### Secret

| 名称 | 类型 | 说明 |
|---|---|---|
| `llm-d-hf-token` | Opaque | HuggingFace Token（本环境填 dummy）|
| `llm-d-inference-gateway-session-key` | Opaque | proxy session 加密密钥 |
| `sh.helm.release.v1.quickstart.v1` | helm.sh/release.v1 | Helm 发布元数据 |

---

## 资源创建来源汇总

| 资源 | 创建方式 | install.sh 步骤 |
|---|---|---|
| GIE CRDs | `kubectl apply --server-side -f gie-v1.5.0.yaml` | Step 1 |
| agentgateway CRDs | `kubectl apply --server-side -f agentgateway-crds/` | Step 2 |
| GatewayClass `agentgateway` | helm agentgateway chart | Step 3 |
| agentgateway controller Deployment/Service/SA | helm agentgateway chart | Step 3 |
| ClusterRole / ClusterRoleBinding | helm agentgateway chart | Step 3 |
| Namespace `llm-d-gateway` | kubectl create namespace | Step 4 |
| Secret `llm-d-hf-token` | kubectl create secret | Step 5 |
| Gateway `llm-d-inference-gateway` | kubectl apply -k (kustomize) | Step 6 |
| **proxy Deployment / Service / ConfigMap / Secret** | **agentgateway controller 自动生成** | — |
| HTTPRoute `quickstart` | helm llm-d-router-gateway | Step 7 |
| InferencePool `quickstart` | helm llm-d-router-gateway | Step 7 |
| Deployment `quickstart-epp` + Service + SA + Role | helm llm-d-router-gateway | Step 7 |
| ConfigMap `quickstart-epp` | helm llm-d-router-gateway | Step 7 |
| Deployment `qwen25-7b-instruct` + Service | deploy-model.sh | 独立脚本 |

---

## 快速状态检查

```bash
# 控制面
kubectl get pods -n agentgateway-system
kubectl get gatewayclass agentgateway

# 数据面 + 工作负载
kubectl get pods,svc -n llm-d-gateway -o wide
kubectl get gateway,httproute,inferencepool -n llm-d-gateway

# RBAC
kubectl get sa,role,rolebinding -n llm-d-gateway
kubectl get clusterrole,clusterrolebinding | grep agentgateway

# 端到端测试
bash test-llmd.sh
```
