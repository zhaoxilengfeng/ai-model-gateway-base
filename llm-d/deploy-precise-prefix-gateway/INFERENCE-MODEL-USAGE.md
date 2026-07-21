# InferenceModel 使用指南

## 概述

`InferenceModel` 是 Gateway API Inference Extension（GIE）定义的 Kubernetes 资源，负责将进入网关的请求 `"model"` 字段与后端 `InferencePool` 绑定，并声明该模型的调度优先级。

**API 信息：**

| 字段 | 值 |
|------|-----|
| apiVersion | `inference.networking.x-k8s.io/v1alpha2` |
| kind | `InferenceModel` |
| scope | Namespaced |
| 来源 | [GIE v0.3.0](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v0.3.0) |

> **注意：** llm-d 当前依赖的是旧版 group `inference.networking.x-k8s.io/v1alpha2`，
> 而 GIE 新版已迁移到 `inference.networking.k8s.io/v1`（见当前集群安装的
> [gie-v1.5.0.yaml](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/tag/v1.5.0)）。
>
> 旧版 group 的使用体现在两处源码：
> - `llm-d-model-service` [go.mod](https://github.com/llm-d/llm-d-model-service/blob/main/go.mod) 依赖 GIE `v0.3.0`，
>   [child_resources.go L417](https://github.com/llm-d/llm-d-model-service/blob/main/internal/controller/child_resources.go#L417)
>   硬编码 `im.APIVersion = "inference.networking.x-k8s.io/v1alpha2"`
> - `llm-d-router` [docs/architecture.md L300](https://github.com/llm-d/llm-d-router/blob/main/docs/architecture.md#L300)
>   明确注明：*"The `InferenceModel` CRD is in the process of being significantly changed in IGW.
>   Once finalized, these changes would be reflected in llm-d as well."*

---

## 核心字段

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: <name>
  namespace: <namespace>
spec:
  modelName: <string>       # 必填，客户端请求里 "model" 字段的值
  poolRef:
    name: <InferencePool>   # 必填，同 namespace 下的 InferencePool 名称
  criticality: <enum>       # 可选，请求优先级
```

### spec.modelName

客户端发请求时 `"model"` 字段填写的名称，**必须与 InferencePool 内模型 pod 实际提供的 served-model-name 一致**。

约束：
- 同一个 InferencePool 内 modelName 必须唯一
- 字段不可变（创建后无法修改）
- 同名冲突时保留最老的 InferenceModel，新建的状态变为 `Ready=false`

### spec.criticality

请求优先级，影响 Pool 过载时 EPP 的处理策略：

| 值 | 含义 | 适用场景 |
|----|------|---------|
| `Critical` | 最高优先级，过载时最后被丢弃 | 线上核心业务 |
| `Standard` | 默认值，正常调度 | 普通 API 服务 |
| `Sheddable` | 最低优先级，Pool 繁忙时 EPP 直接返回 429 | 离线批处理、评测任务 |

未设置时等同于 `Standard`。

---

## 两种使用方式

### 方式一：通过 ModelService operator 自动创建（推荐）

`llm-d-model-service` operator 在处理 `ModelService` CR 时，会读取 BaseConfig ConfigMap 中的 `inferenceModel` 模板，自动创建并管理 `InferenceModel` 实例。

**工作流程：**

```
ModelService CR
  └─ operator 解析 BaseConfig ConfigMap
       ├─ inferenceModel 模板（仅声明骨架）
       └─ mergeInferenceModel() 填入实际值：
            - spec.modelName  ← msvc.spec.routing.modelName
            - spec.poolRef    ← 自动推导 InferencePool 名称
            - metadata.name   ← 自动生成
            - ownerReference  ← 指向 ModelService（级联删除）
```

**BaseConfig 中的 inferenceModel 模板（最简写法）：**

```yaml
# ConfigMap data 中声明骨架，operator 负责填充字段
inferenceModel: |
  apiVersion: inference.networking.x-k8s.io/v1alpha2
  kind: InferenceModel
```

operator 会自动将 `ModelService.spec.routing.modelName` 写入 `spec.modelName`，将关联的 InferencePool 名称写入 `spec.poolRef.name`，无需在模板中手动指定。

**ModelService CR 示例（来自 llm-d-model-service samples）：**

```yaml
apiVersion: llm-d.ai/v1alpha1
kind: ModelService
metadata:
  name: facebook-opt-125m-nixl
spec:
  baseConfigMapRef:
    name: universal-base-config-hf

  routing:
    modelName: facebook/opt-125m   # ← 自动写入 InferenceModel.spec.modelName
    ports:
    - name: app_port
      port: 8000
    - name: internal_port
      port: 8200

  modelArtifacts:
    uri: hf://facebook/opt-125m

  decode:
    replicas: 1
    containers:
    - name: vllm
      args: ["{{ .HFModelName }}"]

  prefill:
    replicas: 1
    containers:
    - name: vllm
      args: ["{{ .HFModelName }}"]
```

**operator 创建后的集群状态：**

```
$ kubectl get inferencemodel
NAME                     MODEL NAME          INFERENCE POOL                         CRITICALITY   AGE
facebook-opt-125m-nixl   facebook/opt-125m   facebook-opt-125m-nixl-inference-pool                3h22m
```

`ModelService` 的 status 中也会记录对应引用：

```yaml
status:
  inferenceModelRef: facebook-opt-125m-nixl
  inferencePoolRef: facebook-opt-125m-nixl-inference-pool
  decodeDeploymentRef: facebook-opt-125m-nixl-decode
  prefillDeploymentRef: facebook-opt-125m-nixl-prefill
  eppDeploymentRef: facebook-opt-125m-nixl-epp
```

---

### 方式二：手动创建（当前 precise-prefix-gateway 方案）

不使用 `ModelService` operator 时，需要手动创建 `InferenceModel`。
当前 `precise-prefix-gateway` 部署方案绕过了 operator，所有资源均手动管理，因此需要单独安装 CRD 并手动创建实例。

**安装 CRD：**

```bash
bash inference-model/install-inferencemodel-crd.sh
```

**创建 InferenceModel 实例：**

```bash
bash inference-model/deploy-inferencemodel.sh <model-name> [criticality]

# 示例
bash inference-model/deploy-inferencemodel.sh qwen25-7b-instruct Standard
bash inference-model/deploy-inferencemodel.sh glm-5-2-fp8 Critical
```

或直接 apply YAML：

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: qwen25-7b-instruct
  namespace: llm-d-precise-prefix-gw
spec:
  modelName: qwen25-7b-instruct
  poolRef:
    name: precise-prefix-cache-routing
  criticality: Standard
```

---

## 与 InferencePool 的关系

```
客户端请求 "model": "qwen25-7b-instruct"
         │
         ▼
    Gateway (agentgateway)
         │
         ▼
    HTTPRoute ──► InferencePool (precise-prefix-cache-routing)
                       │
                  InferenceModel   ← 声明 modelName + criticality
                       │           EPP 据此做过载保护决策
                       ▼
                  EPP（Endpoint Picker）
                  ├── 读取 InferenceModel.criticality
                  ├── 在 Pool 过载时按优先级丢弃 Sheddable 请求
                  └── 路由到具体模型 pod
```

`InferencePool` 定义"有哪些 pod 可以服务"，`InferenceModel` 定义"哪个 model 名称映射到这个 pool，以及它的优先级"。两者必须在同一个 namespace 下。

---

## 典型场景：混合负载过载保护

同一批 GPU 资源同时承载在线推理和离线评测时：

```yaml
# 在线推理 — Critical，最后被丢弃
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: qwen25-7b-online
spec:
  modelName: qwen25-7b-instruct
  poolRef:
    name: precise-prefix-cache-routing
  criticality: Critical

---
# 离线评测 — Sheddable，过载时第一个被丢弃（返回 429）
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: qwen25-7b-batch
spec:
  modelName: qwen25-7b-instruct-batch
  poolRef:
    name: precise-prefix-cache-routing
  criticality: Sheddable
```

评测任务请求 `"model": "qwen25-7b-instruct-batch"`，GPU 负载高时 EPP 优先保障 `Critical` 的在线请求，对 `Sheddable` 请求返回 429。

---

## 注意事项

1. **modelName 不可变**：创建后无法修改，需要删除重建
2. **同 namespace 唯一**：同一 InferencePool 内 modelName 不能重复，否则新建的 InferenceModel 状态为 `Ready=false`
3. **CRD 需单独安装**：当前集群 `precise-prefix-gateway` 方案未安装，使用前需执行 `install-inferencemodel-crd.sh`
4. **EPP 支持程度**：当前 `precise-prefix-cache-routing` EPP 实现中，`criticality` 调度逻辑取决于 llm-d-router 版本。[llm-d-router 架构文档 L300](https://github.com/llm-d/llm-d-router/blob/main/docs/architecture.md#L300) 明确说明 `InferenceModel` 正在上游大改，建议关注后续版本同步情况

---

## 参考

| 资源 | 链接 |
|------|------|
| GIE InferenceModel CRD 定义 | [inferencemodel.yaml](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/config/crd/experimental/bases/inference.networking.k8s.io_inferencemodels.yaml) |
| llm-d-model-service operator | [github.com/llm-d/llm-d-model-service](https://github.com/llm-d/llm-d-model-service) |
| llm-d-router 架构文档 | [docs/architecture.md](https://github.com/llm-d/llm-d-router/blob/main/docs/architecture.md) |
| ModelService API 类型 | [api/v1alpha1/modelservice_types.go](https://github.com/llm-d/llm-d-model-service/blob/main/api/v1alpha1/modelservice_types.go) |
| nixl-xpyd 完整示例 | [samples/nixl-xpyd/](https://github.com/llm-d/llm-d-model-service/tree/main/samples/nixl-xpyd) |
