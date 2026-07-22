# render Service 详解

## 一句话定义

render service 是一个**纯 tokenizer HTTP 服务**，专门为 EPP 的 `token-producer` 插件提供 prompt → token_ids 的转换能力，是精准前缀路由中 KV 块哈希索引能够工作的前提。

---

## 为什么需要 render service

精准前缀路由的核心是：**把请求的 prompt 切成 64-token 的块，对每块计算哈希，然后去 EPP 的倒排索引里查哪个 vLLM pod 已经缓存了这些块**。

这个流程的第一步——把 prompt 文本转成 token ID 序列——需要 tokenizer。但 EPP 本身是 Go 程序，不内置 tokenizer（tokenizer 逻辑与模型强绑定，实现复杂且版本各异），所以 EPP 通过 HTTP 调用 render service 来完成这一步。

**没有 render service → token-producer 失效 → 无法计算 block hash → 精准前缀路由降级为普通负载感知路由**（queue + kv-util scorer 仍工作，推理请求不中断，只是路由不再精准）。

---

## render service 的本质

render service 运行的是 `vllm launch render` 子命令——这是 vLLM 内置的轻量级 HTTP 服务模式，**只加载 tokenizer，不加载模型权重，不需要 GPU**。

```bash
# 实际启动命令（从 pod spec 读取）
vllm launch render \
  /root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/a09a35458c702b33eeacc393d103063234e8bc28 \
  --port=8000 \
  --served-model-name=qwen25-7b-instruct
```

加载的内容：仅 tokenizer 文件（`tokenizer.json`、`tokenizer_config.json`、`special_tokens_map.json` 等），总计几 MB，启动极快（约 30s）。

---

## render service 与模型的对应关系

**每个模型必须有一个独立的 render service**，因为不同模型使用不同的词表（vocabulary）和 tokenizer 实现，同一个 prompt 经过不同模型的 tokenizer 会产生完全不同的 token_ids，进而产生不同的 block hash，导致路由决策错误。

```
示例：同一 prompt "你好" 在不同模型下的 token_ids

Qwen2.5-7B-Instruct:   [108386]               (1 个 token)
LLaMA-3-8B:            [57668, 53901]          (2 个 token，BPE 不同)
Baichuan2-7B:          [92395]                 (1 个 token，但 id 不同)
```

如果 render service 使用了错误的模型 tokenizer，计算出的 block hash 与 vLLM 实际缓存的 block hash 不一致，精准路由会**静默失效**（不报错，但永远命中不到缓存，prefix-cache-scorer 持续 score 0）。

### 多模型部署的资源映射

| 模型 | vLLM pods | render service | EPP |
|---|---|---|---|
| Qwen2.5-7B | pod-A, pod-B | render-qwen25-7b × 3 | epp-qwen25-7b × 2 |
| LLaMA-3-8B | pod-C, pod-D | render-llama3-8b × 3 | epp-llama3-8b × 2 |
| Qwen2.5-72B | pod-E, pod-F | render-qwen25-72b × 3 | epp-qwen25-72b × 2 |

每个模型有自己独立的 InferencePool → EPP → render 链路，通过 HTTPRoute 的 path 或 header 将不同模型的请求分发到对应的链路。

每个模型的 EPP `token-producer.vllm.url` 指向各自模型的 render service：

```yaml
# 模型 Qwen2.5-7B 的 EPP 配置
- type: token-producer
  parameters:
    modelName: qwen25-7b-instruct
    vllm:
      url: "http://qwen25-7b-render:8000"

# 模型 LLaMA-3-8B 的 EPP 配置（独立的 EPP Deployment）
- type: token-producer
  parameters:
    modelName: llama3-8b-instruct
    vllm:
      url: "http://llama3-8b-render:8000"
```

### 同一模型多副本：共用一个 render service

同一模型的多个 vLLM pod 使用相同的词表，因此可以共用一个 render service（通过 Service 做负载均衡）：

```
同一模型的 N 个 vLLM pod
  └── 共用同一个 render Service（3 副本）
        └── 每个副本加载相同的 tokenizer 文件
```

---

## render service 提供的 API

render service 是标准 vLLM HTTP 服务的子集，仅暴露以下接口：

### GET /v1/models

```json
{
  "data": [{
    "id": "qwen25-7b-instruct",
    "root": "/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/a09a35458c702b33eeacc393d103063234e8bc28"
  }]
}
```

### POST /v1/completions/render（核心接口）

EPP `token-producer` 调用此接口将 prompt 转换为 token_ids：

**请求**：
```json
{
  "model": "qwen25-7b-instruct",
  "prompt": "请你详细解释 Transformer 架构中多头自注意力机制的数学原理，包括 Query Key Value 矩阵的计算方式"
}
```

**响应**（实测）：
```json
[{
  "request_id": "cmpl-910774326224507f",
  "token_ids": [112720, 100700, 104136, 62379, 93920, 114, 77835, 15946,
                42140, 64355, 35926, 108260, 100674, 9370, 104552, 105318,
                3837, 100630, 11361, 5309, 5162, 10236, 253, 102, 99854,
                9370, 100768, 75768],
  "model": "qwen25-7b-instruct"
}]
```

上述 prompt 被 tokenize 为 **28 个 token**，按 block-size=64 分组为 1 个块（未满 64），对这 1 个块计算哈希，EPP 用此哈希去索引中查命中情况。

---

## EPP 如何使用 render service

EPP `token-producer` 插件的完整调用链：

```
请求到达 EPP
  │
  ▼
token-producer 调用
  http://precise-prefix-cache-routing-render:8000/v1/completions/render
  请求体: {model: "qwen25-7b-instruct", prompt: <用户的 prompt>}
  │
  ▼
返回 token_ids = [112720, 100700, 104136, ...]
  │
  ▼
precise-prefix-cache-producer 按 block_size=64 分组
  block_0: token_ids[0:64]   → SHA256 → hash_A
  block_1: token_ids[64:128] → SHA256 → hash_B
  ...
  │
  ▼
查倒排索引（key: hash → value: {pod_ip: 命中块数}）
  hash_A → {10.244.117.136: 3, 10.244.142.246: 0}  # host-004 命中 3 块
  hash_B → {10.244.117.136: 3, 10.244.142.246: 0}
  │
  ▼
prefix-cache-scorer 计算各 pod 的命中比例，作为 scoring 分数
  host-004: 命中率高 → 高分 → 被选中
  host-002: 命中率低 → 低分 → 不被选中
```

---

## 当前部署状态

```
名称: precise-prefix-cache-routing-render
镜像: docker.io/vllm/vllm-openai-cpu:v0.23.0（CPU-only，无 CUDA）
副本: 3（已扩容，消除单点）
```

| Pod | 节点 | IP |
|---|---|---|
| `*-2cmbd` | host-000-004 | 10.244.117.135 |
| `*-2z5gv` | host-000-005 | 10.244.41.132 |
| `*-8zgvh` | host-000-005 | 10.244.41.131 |

Service ClusterIP：`10.101.160.128:8000`（kube-proxy 负载均衡到 3 个副本）

资源配置（每个副本）：
- 请求：1 CPU / 4Gi 内存
- 上限：4 CPU / 12Gi 内存
- **不申请 GPU**

---

## 三处一致性约束

render service 的 `--served-model-name` 必须与以下两处完全一致，否则 EPP 请求 tokenize 时返回 404：

```
render  --served-model-name=qwen25-7b-instruct
          ↕ 必须完全一致
EPP     token-producer.modelName=qwen25-7b-instruct
          ↕ 必须完全一致
vLLM    --served-model-name=qwen25-7b-instruct
```

不一致时的错误表现：

```
EPP 日志：
DataProducer "token-producer/token-producer" failed:
  tokenization failed: vLLM render returned status 404:
  {"error": {"message": "The model `Qwen/Qwen3-32B` does not exist."}}
```

---

## 常见问题

### 部署了多个模型，render service 怎么部署

每个模型对应一个独立的 render service（Deployment + Service），使用各自模型的 tokenizer 文件，通过不同的 Service 名称区分，各自的 EPP 配置指向对应的 render service URL。同一模型的多个 vLLM pod 共用一套 render service。

### render 挂掉怎么办

精准路由降级（不影响推理）。EPP 日志出现：

```
DataProducer "token-producer" failed: ... connection refused
```

此时 `prefix-cache-scorer` score 全为 0，路由回退到 queue + kv-util scorer 的负载感知模式。render 恢复后 EPP 自动重试，无需重启。

### render 启动失败：联网下载 tokenizer

根因：模型路径参数传的是 HuggingFace 模型 ID（如 `Qwen/Qwen3-32B`），而不是本地路径。

修复：必须传本地 snapshot 绝对路径，并设置 `HF_HUB_OFFLINE=1`。详见 [troubleshooting/render-service-tokenizer-download.md](../../troubleshooting/render-service-tokenizer-download.md)。

### render 副本数建议

官方指南建议 3 副本（与 EPP 副本数解耦，独立扩容）。tokenize 属于 CPU 轻量操作，单副本吞吐约 200-500 req/s，3 副本足以覆盖大多数场景。多模型部署时每个模型的 render service 各自独立扩容。

---

## 参考资料

- [vllm launch render — vLLM 官方文档](https://docs.vllm.ai/en/latest/cli/launch/render/)
- [Master KV cache aware routing with llm-d — Red Hat Developer](https://developers.redhat.com/articles/2025/10/07/master-kv-cache-aware-routing-llm-d-efficient-ai-inference)
