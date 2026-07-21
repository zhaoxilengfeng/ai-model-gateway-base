# install.sh 资源清单

`install.sh` 是一次性全局基础设施安装脚本，完成后通过 `install-pool.sh` 为每个模型创建独立的推理池。

## 参考文档

| 组件 | 文档链接 |
|------|---------|
| GIE（Gateway API Inference Extension）概览 | [gateway-api-inference-extension.sigs.k8s.io](https://gateway-api-inference-extension.sigs.k8s.io/) |
| GIE API 概念（InferencePool 介绍） | [concepts/api-overview](https://gateway-api-inference-extension.sigs.k8s.io/concepts/api-overview/) |
| InferencePool API 类型 | [api-types/inferencepool](https://gateway-api-inference-extension.sigs.k8s.io/api-types/inferencepool/) |
| GIE v1 API 参考 | [reference/spec](https://gateway-api-inference-extension.sigs.k8s.io/reference/spec/) |
| GIE GitHub Releases | [releases](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases) |
| Agentgateway 概览 | [about/overview](https://agentgateway.dev/docs/kubernetes/latest/about/overview.md) |
| Agentgateway Helm 安装 | [install/helm](https://agentgateway.dev/docs/kubernetes/latest/install/helm.md) |
| Agentgateway 高级安装选项 | [install/advanced](https://agentgateway.dev/docs/kubernetes/latest/install/advanced.md) |
| AgentgatewayParameters API 参考 | [reference/api-kubespec/parameters](https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/parameters.md) |
| AgentgatewayBackend API 参考 | [reference/api-kubespec/backends](https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/backends.md) |
| AgentgatewayPolicy API 参考 | [reference/api-kubespec/policies](https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/policies.md) |
| Agentgateway 多推理池配置 | [llm/multiple-inference-pools](https://agentgateway.dev/docs/kubernetes/latest/llm/multiple-inference-pools.md) |
| Agentgateway vLLM 集成 | [integrations/vllm](https://agentgateway.dev/docs/kubernetes/latest/integrations/vllm.md) |
| Agentgateway GitHub | [github.com/agentgateway/agentgateway](https://github.com/agentgateway/agentgateway) |

> **InferenceModel** 是 GIE 的 alpha 资源（`inference.networking.k8s.io/v1alpha2`），当前官方文档尚无独立页面。
> 其用途（请求优先级 / model alias）见 `inference-model/` 目录下的脚本注释，以及 [GIE GitHub 源码](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/config/crd/experimental/bases/inference.networking.k8s.io_inferencemodels.yaml)。

---

## 步骤总览

| 步骤 | 操作 | 目标集群范围 |
|------|------|-------------|
| 1 | 安装 GIE CRDs | 集群级（cluster-scoped） |
| 2 | 安装 Agentgateway CRDs | 集群级 |
| 3 | 安装 Agentgateway Controller（Helm） | `agentgateway-system` namespace |
| 4 | 创建推理 Namespace | namespace `llm-d-precise-prefix-gw` |
| 5 | 创建 HuggingFace Token Secret | `llm-d-precise-prefix-gw` namespace |

---

## 步骤 1 — Install GIE CRDs

**来源文件：** `$DEPLOY_DIR/gie-v1.5.0.yaml`（[GIE v1.5.0](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v1.5.0)）

安装以下 CustomResourceDefinition：

| CRD 名称 | Kind | API Group | 用途 |
|----------|------|-----------|------|
| `inferencepools.inference.networking.k8s.io` | [`InferencePool`](https://gateway-api-inference-extension.sigs.k8s.io/api-types/inferencepool/) | `inference.networking.k8s.io` | 定义一组提供同一模型的推理后端 pod 集合，供 EPP（Endpoint Picker）调度 |

> `InferencePool` 是 llm-d 路由体系的核心资源，EPP 根据它发现可调度的模型 pod。

---

## 步骤 2 — Install Agentgateway CRDs

**来源目录：** `$DEPLOY_DIR/agentgateway-crds/`（[agentgateway v1.3.1](https://github.com/agentgateway/agentgateway/releases/tag/v1.3.1)）

安装以下 3 个 CustomResourceDefinition：

| CRD 名称 | Kind | API Group | 用途 |
|----------|------|-----------|------|
| `agentgatewaybackends.agentgateway.dev` | [`AgentgatewayBackend`](https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/backends.md) | `agentgateway.dev` | 定义 agentgateway 后端目标（推理服务的上游地址） |
| `agentgatewayparameters.agentgateway.dev` | [`AgentgatewayParameters`](https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/parameters.md) | `agentgateway.dev` | 为 GatewayClass 提供 agentgateway 特定参数（如镜像、功能开关） |
| `agentgatewaypolicies.agentgateway.dev` | [`AgentgatewayPolicy`](https://agentgateway.dev/docs/kubernetes/latest/reference/api-kubespec/policies.md) | `agentgateway.dev` | 附加到 Gateway/Route 的策略（流量控制、超时、重试等） |

---

## 步骤 3 — Install Agentgateway Controller（Helm）

**Helm release 名称：** `agentgateway`
**安装 namespace：** `agentgateway-system`（自动创建）
**Chart 版本：** v1.3.1（参见 [Helm 安装文档](https://agentgateway.dev/docs/kubernetes/latest/install/helm.md) / [高级选项](https://agentgateway.dev/docs/kubernetes/latest/install/advanced.md)）
**启用选项：** `inferenceExtension.enabled=true`

Helm 在 `agentgateway-system` namespace 中创建以下资源：

| 资源类型 | 名称 | 说明 |
|----------|------|------|
| `Deployment` | `agentgateway` | Agentgateway controller 主进程，负责将 Gateway CRD 转译为 Envoy xDS 配置并下发 |
| `Service` | `agentgateway` | Controller 对外暴露的管理接口 |
| `ServiceAccount` | `agentgateway` | Controller pod 的身份 |
| `ClusterRole` | `agentgateway-agentgateway-system` | 授予 controller 读写 Gateway、HTTPRoute、InferencePool 等资源的权限 |
| `ClusterRoleBinding` | `agentgateway-role-agentgateway-system` | 将上述 ClusterRole 绑定到 ServiceAccount |

> 此 controller 不包含 CRDs 本身（`--skip-crds`），CRDs 已在步骤 1/2 单独安装，方便版本独立管理。

---

## 步骤 4 — Create Namespace

创建推理工作负载使用的 namespace：

| 资源类型 | 名称 | 说明 |
|----------|------|------|
| `Namespace` | `llm-d-precise-prefix-gw`（可通过 `$NAMESPACE` 覆盖）| 后续所有模型 Deployment、Service、InferencePool、EPP 均部署在此 namespace 下 |

> 使用 `--dry-run=client -o yaml | kubectl apply -f -` 方式，namespace 已存在时幂等跳过。

---

## 步骤 5 — Create HF Token Secret

在推理 namespace 中创建 HuggingFace token 密钥：

| 资源类型 | 名称 | namespace | 说明 |
|----------|------|-----------|------|
| `Secret` | `llm-d-hf-token` | `llm-d-precise-prefix-gw` | 存储 `HF_TOKEN`，供模型 pod 下载私有 HuggingFace 模型时使用；当前部署的模型均离线加载（`HF_HUB_OFFLINE=1`），此 secret 为占位默认值 `dummy` |

---

## 安装后整体资源视图

```
集群级（cluster-scoped）
├── CRD: inferencepools.inference.networking.k8s.io          ← 步骤 1
├── CRD: agentgatewaybackends.agentgateway.dev               ← 步骤 2
├── CRD: agentgatewayparameters.agentgateway.dev             ← 步骤 2
├── CRD: agentgatewaypolicies.agentgateway.dev               ← 步骤 2
├── ClusterRole: agentgateway-agentgateway-system            ← 步骤 3
└── ClusterRoleBinding: agentgateway-role-agentgateway-system ← 步骤 3

namespace: agentgateway-system
├── Deployment: agentgateway                                 ← 步骤 3
├── Service: agentgateway                                    ← 步骤 3
└── ServiceAccount: agentgateway                            ← 步骤 3

namespace: llm-d-precise-prefix-gw
├── (namespace 本身)                                         ← 步骤 4
└── Secret: llm-d-hf-token                                  ← 步骤 5
```

完成后通过 `install-pool.sh` 为每个模型在 `llm-d-precise-prefix-gw` 中继续创建推理池资源（render Service、Gateway、EPP、HTTPRoute、InferencePool）。
