# 基准测试数据集

本文档列出可用于 gateway-benchmark 的开源数据集，按类型分类，包含下载地址和使用方式。

---

## 数据集类型与 inference-perf 支持情况

| `data.type` | 对应数据集 | 场景 |
|-------------|-----------|------|
| `random` | 无需下载，自动生成 | 快速验证，当前默认 |
| `shared_prefix` | 无需下载，自动生成 | 前缀缓存效果验证 |
| `shareGPT` | ShareGPT | 真实多轮对话 |
| `cnn_dailymail` | CNN/DailyMail | 长文摘要（长输入短输出） |
| `otel_trace_replay` | Azure Trace / Qwen Trace | 生产流量回放 |
| `weka_trace_replay` | Qwen Coder Trace / ASTRA | 多轮 Agent 编程场景回放 |
| `conversation_replay` | 任意多轮对话 JSON | 自定义对话回放 |

> **编码场景**：推理性能压测推荐 `weka_trace_replay`（Qwen Coder Trace 或 ASTRA），
> 能力评测（能否写出正确代码）才用 HumanEval / MBPP，两者用途不同。

---

## 1. 生产流量 Trace（最接近真实场景）

### Qwen / 阿里百炼 Trace

- **仓库**：https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon
- **下载**：
  ```bash
  # block size 16 版本（推荐）
  wget https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon/raw/refs/heads/main/qwen_traceA_blksz_16.jsonl

  # block size 32 版本
  wget https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon/raw/refs/heads/main/qwen_traceA_blksz_32.jsonl
  ```
- **字段**：请求时间戳、input token 数、output token 数、前缀长度
- **适合场景**：测试精确前缀路由（KV cache 命中率），与当前集群 Qwen 模型匹配度最高
- **inference-perf data.type**：`otel_trace_replay`

### Azure LLM Inference Trace 2023

- **仓库**：https://github.com/Azure/AzurePublicDataset
- **数据说明**：https://github.com/Azure/AzurePublicDataset/blob/master/AzureLLMInferenceTrace2023.md
- **文件**：
  - `AzureLLMInferenceTrace_conv.csv`：多轮对话类请求（ContextTokens、GeneratedTokens）
  - `AzureLLMInferenceTrace_code.csv`：代码生成类请求
- **下载**：访问上方数据说明页面，获取 Azure Blob Storage 下载链接
- **适合场景**：模拟真实生产负载，学术界最常用
- **inference-perf data.type**：`otel_trace_replay`

### BurstGPT

- **仓库**：https://github.com/HKUDS/BurstGPT
- **论文**：https://arxiv.org/abs/2401.17644
- **特点**：包含突发流量模式，适合测试服务在流量峰值下的表现
- **适合场景**：自动扩缩容、流量峰值压测

---

## 2. 对话数据集（多轮真实对话）

### ShareGPT

- **来源**：ChatGPT 真实用户对话（脱敏）
- **Hugging Face**：https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered
- **直接下载**：
  ```bash
  wget https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json

  # 国内镜像加速
  HF_ENDPOINT=https://hf-mirror.com wget https://hf-mirror.com/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
  ```
- **特点**：多轮对话，输入长度分布自然，vLLM / SGLang 默认基准数据集
- **inference-perf data.type**：`shareGPT`
- **profile 示例**：
  ```yaml
  data:
    type: shareGPT
    path: /requests/datasets/ShareGPT_V3_unfiltered_cleaned_split.json
  ```

---

## 3. 任务型数据集

### CNN / DailyMail

- **特点**：新闻摘要，长输入（文章）+ 短输出（摘要），典型 RAG / 摘要场景
- **Hugging Face**：https://huggingface.co/datasets/abisee/cnn_dailymail
- **inference-perf data.type**：`cnn_dailymail`（内置支持，无需手动下载）
- **profile 示例**：
  ```yaml
  data:
    type: cnn_dailymail
  ```

---

## 4. 编码场景数据集

编码场景有两类用途，需区分：

### 4.1 吞吐/延迟压测（Agent 编程真实场景）

**ASTRA**（Agentic Serving TRAce Dataset）是目前最权威的 Agent 编程推理性能数据集（2025年）：

- **论文**：https://arxiv.org/abs/2502.15981
- **仓库**：https://github.com/WukLab/ASTRA
- **数据来源**：SWE-bench（Claude 3.5 / GPT-4o）、OpenHands 生产环境、内部编程 Agent，共 **27,811 个 session、130万+ 轮次**
- **核心特征**：
  - 每个 session 平均 33-47 轮，比 ShareGPT 上下文长 3-10 倍
  - 频繁 tool call（bash、文件编辑、搜索），造成突发 prefill 峰值
  - 跨轮次 KV cache 复用可节省高达 60% prefill 计算
- **inference-perf data.type**：`weka_trace_replay`
- **profile 示例**：
  ```yaml
  load:
    type: trace_session_replay
    stages:
      - concurrent_sessions: 4
  data:
    type: weka_trace_replay
    weka_trace_replay:
      trace_directory: /requests/datasets/astra
      use_static_model: true
      static_model_name: qwen25-7b-instruct
      default_block_size: 16
  ```

**Qwen Coder Trace**（阿里百炼，代码补全真实流量）：

- **仓库**：https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon
- **下载**：
  ```bash
  # block size 16（与 llm-d EPP 默认配置一致，推荐）
  wget https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon/raw/refs/heads/main/qwen_coder_blksz_16.jsonl
  ```
- **inference-perf data.type**：`weka_trace_replay`
- **特点**：包含 `hash_ids`（KV block 哈希），专为测试精确前缀路由命中率设计

**AgentIQ 数据集**（含 SWE-bench 工具调用 trace）：

- **论文**：https://arxiv.org/abs/2505.07942
- **仓库**：https://github.com/MikeGu721/AgentIQ
- **特点**：multi-turn tool call 交互 trace，含 system prompt 复用场景，适合测 KV cache reuse 效果

### 4.2 代码能力评测（正确性，与压测无关）

以下数据集用于测模型**能否写出正确代码**，不用于吞吐/延迟压测：

| 数据集 | 仓库 | 说明 |
|--------|------|------|
| HumanEval | https://github.com/openai/human-eval | 164 道 Python 编程题，pass@k 指标 |
| MBPP | https://github.com/google-research/google-research/tree/master/mbpp | 500 个基础 Python 问题 |
| EvalPlus（增强版） | https://github.com/evalplus/evalplus | HumanEval / MBPP 增强版，测试更严格 |
| HumanEval Pro | https://arxiv.org/abs/2412.21199 | 自调用代码生成，考察多步推理 |

---

数据集文件需放到 workload PVC 内，harness pod 才能访问：

```bash
# 在控制节点上操作
mkdir -p /mnt/llmdbench-workload-pvc/datasets

# 拷贝数据集
cp qwen_traceA_blksz_16.jsonl /mnt/llmdbench-workload-pvc/datasets/
cp ShareGPT_V3_unfiltered_cleaned_split.json /mnt/llmdbench-workload-pvc/datasets/

# 同步到所有 worker 节点
for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc/datasets"
  scp /mnt/llmdbench-workload-pvc/datasets/* root@$node:/mnt/llmdbench-workload-pvc/datasets/
done
```

在 profile 中使用 `/requests/datasets/<文件名>` 路径引用（harness pod 将 PVC 挂载到 `/requests`）。

---

## 5. 数据集选型建议

| 测试目的 | 推荐数据集 |
|----------|-----------|
| 快速验通 / 日常 CI | `random`（无需准备） |
| 验证前缀缓存效果 | `qwen_traceA_blksz_16.jsonl`（与当前模型最匹配） |
| 模拟真实生产负载 | Azure LLM Trace 2023 |
| 多轮对话场景 | ShareGPT |
| 文档摘要 / RAG 场景 | CNN/DailyMail |
| 突发流量压测 | BurstGPT |
| **Agent 编程场景（推荐，2025年最新）** | **ASTRA**（https://github.com/WukLab/ASTRA） |
| Agent 编程 + 前缀路由验证 | Qwen Coder Trace（`qwen_coder_blksz_16.jsonl`） |
