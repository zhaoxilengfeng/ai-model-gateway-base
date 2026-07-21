# llm-d 推理模型资源说明

## 资源名称澄清

llm-d 体系中有两个名字相近但**来自不同 API Group** 的资源，容易混淆：

| 资源 | API Group / Version | 来源 | 用途 |
|------|---------------------|------|------|
| `InferenceModel` | `inference.networking.x-k8s.io/v1alpha2` | GIE 上游规范（alpha） | 请求优先级（criticality）/ model alias |
| `InferenceModelRewrite` | `llm-d.ai/v1alpha2` | llm-d 自定义 | 请求 model 字段改写，用于流量分割和灰度发布 |

### 哪些组件实际使用了 InferenceModel

源码分析结论（基于三个核心仓库）：

| 仓库 | 使用情况 |
|------|---------|
| `llm-d-model-service` | **使用**。`ModelService` operator 会自动创建 `InferenceModel` 实例（API group: `inference.networking.x-k8s.io/v1alpha2`，GIE v0.3.0）。samples 中有完整示例，`criticality` 字段默认 `Standard` |
| `llm-d-router`（EPP） | **未直接使用**，架构文档注明 `InferenceModel` CRD 正在 GIE 上游大改，"待上游 finalized 后同步到 llm-d" |
| `llm-d-inference-scheduler` | **未使用**，同 router 的架构说明 |
| `llm-d`（文档仓库） | **未使用**，文档中只有 `InferenceModelRewrite` |

### 两套部署方案的对应关系

| 部署方案 | InferenceModel | 说明 |
|----------|---------------|------|
| `deploy-precise-prefix-gateway/`（当前在用） | **未安装、未使用** | 直接用 Helm 管理 EPP + InferencePool，不走 ModelService operator |
| `deploy/`（旧版 llm-d v0.8.1） | **安装了 CRD，由 model-service operator 自动创建实例** | ModelService → operator → 自动创建 InferenceModel + InferencePool + EPP |

**当前集群未安装 `InferenceModel` CRD**，因为当前方案绕过了 `llm-d-model-service` operator，手动管理所有资源。

---

## llm-d 核心资源一览

| 资源 | API Group | Version | 用途 | 文档 |
|------|-----------|---------|------|------|
| `InferencePool` | `inference.networking.k8s.io` | `v1` | 定义模型 pod 池，EPP 据此调度 | [inferencepool.md](https://github.com/llm-d/llm-d/blob/main/docs/api-reference/inferencepool.md) |
| `InferenceObjective` | `llm-d.ai` | `v1alpha2` | 声明模型性能目标（优先级、延迟 SLO） | [inferenceobjective.md](https://github.com/llm-d/llm-d/blob/main/docs/api-reference/inferenceobjective.md) |
| `InferenceModelRewrite` | `llm-d.ai` | `v1alpha2` | 改写请求 model 字段，实现流量分割和灰度发布 | [inferencemodelrewrite.md](https://github.com/llm-d/llm-d/blob/main/docs/api-reference/inferencemodelrewrite.md) |

---

## InferenceModelRewrite — LoRA 灰度发布 Demo

> **来源：** `/root/llm-d/docs/operations/rollouts/adapter-rollout.md`
>
> **场景：** 同一 InferencePool 内部署了两个 LoRA adapter 版本，客户端请求的 model 名称不变，
> 通过调整 weight 实现灰度切流，最终完成无损版本升级。

### 前置条件

在 vLLM 容器中添加以下环境变量，开启动态 LoRA 加载：

```yaml
env:
- name: VLLM_ALLOW_RUNTIME_LORA_UPDATING
  value: "True"
- name: VLLM_PLUGINS
  value: "lora_filesystem_resolver"
- name: VLLM_LORA_RESOLVER_CACHE_DIR
  value: "/adapters"
```

适配器放置于缓存目录的子目录下：

```
/adapters/
├── small-segment-lora-v1/
└── small-segment-lora-v2/
```

安装 `InferenceModelRewrite` CRD（来自 llm-d-router）：

```bash
kubectl apply -f https://github.com/llm-d/llm-d-router/releases/download/v0.9.0/manifests.yaml
```

---

### 步骤 1 — 建立基线（全量 → v1）

将客户端请求的 `small-segment-lora` 固定路由到 `small-segment-lora-v1`：

```yaml
apiVersion: llm-d.ai/v1alpha2
kind: InferenceModelRewrite
metadata:
  name: small-segment-lora-rewrite
spec:
  poolRef:
    group: inference.networking.k8s.io
    name: vllm-qwen3-32b
  rules:
    - matches:
        - model:
            type: Exact
            value: small-segment-lora
      targets:
        - modelRewrite: "small-segment-lora-v1"
```

验证：响应体中 `"model"` 字段应返回 `small-segment-lora-v1`。

---

### 步骤 2 — 灰度切流（90% v1 / 10% v2）

```yaml
      targets:
        - modelRewrite: "small-segment-lora-v1"
          weight: 90
        - modelRewrite: "small-segment-lora-v2"
          weight: 10
```

> weight 的计算方式：`weight / sum(all weights)`，此处 v2 占 10/100 = 10%。

---

### 步骤 3 — 扩大比例（50% / 50%）

```yaml
      targets:
        - modelRewrite: "small-segment-lora-v1"
          weight: 50
        - modelRewrite: "small-segment-lora-v2"
          weight: 50
```

---

### 步骤 4 — 全量切换（100% → v2）

```yaml
      targets:
        - modelRewrite: "small-segment-lora-v2"
          weight: 100
```

---

### 步骤 5 — 清理旧版本

```bash
# 从缓存目录删除旧 adapter（停止新的加载）
rm -rf /adapters/small-segment-lora-v1

# 如需立即释放 VRAM，调用 vLLM 卸载接口
curl -X POST http://${POD_IP}:8000/v1/unload_lora_adapter \
  -H "Content-Type: application/json" \
  -d '{"lora_name": "small-segment-lora-v1"}'
```

---

### 流量验证脚本

发送 N 次请求，统计实际路由分布：

```bash
#!/bin/bash
target_ip="${IP}"
total_requests=20
count_v1=0; count_v2=0

for ((i=1; i<=total_requests; i++)); do
  model_name=$(curl -s "http://${target_ip}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"small-segment-lora","messages":[{"role":"user","content":"test"}],"max_completion_tokens":1}' \
    | jq -r '.model')
  [[ "$model_name" == "small-segment-lora-v1" ]] && ((count_v1++))
  [[ "$model_name" == "small-segment-lora-v2" ]] && ((count_v2++))
done

echo "Traffic Split Results, total requests: ${total_requests}"
echo "small-segment-lora-v1: ${count_v1} requests"
echo "small-segment-lora-v2: ${count_v2} requests"
```

---

## InferenceModelRewrite 规则优先级

多条规则共存时按以下顺序决策：

1. **精确匹配优先**：`type: Exact` 的 model 匹配优先于空 matches（匹配全部）
2. **资源创建时间**：同一 pool、同一 match 有多个 InferenceModelRewrite 时，最老的资源优先
3. **规则顺序**：同一资源内，列表中第一条匹配的规则生效

---

## InferenceModel（GIE alpha）说明

`InferenceModel`（`inference.networking.x-k8s.io/v1alpha2`，GIE v0.3.0）是 GIE 上游规范中的资源。

**llm-d-model-service operator 会自动创建它**，当你通过 `ModelService` CRD 部署模型时，operator 会自动生成对应的 `InferenceModel` 实例。如果手动管理资源（当前方案），则需要手动创建。

主要字段：

| 字段 | 用途 |
|------|------|
| `spec.modelName` | 绑定的模型名称，必须与 InferencePool 内 pod 提供的 served-model-name 一致 |
| `spec.poolRef` | 引用的 InferencePool 名称 |
| `spec.criticality` | 请求优先级：`Critical` / `Standard`（默认）/ `Sheddable` |

`Sheddable` 级别的请求在 Pool 过载时会被 EPP 主动返回 429，保护高优先级流量。

> **注意：** llm-d-router 架构文档明确说明 `InferenceModel` CRD 正在 GIE 上游进行较大改动，
> 变更 finalized 后会同步到 llm-d。当前 `precise-prefix-gateway` 部署方案绕过了 `ModelService` operator，
> 因此不依赖此资源。如需启用，见 `inference-model/install-inferencemodel-crd.sh`。
