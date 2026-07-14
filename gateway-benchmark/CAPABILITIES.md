# Gateway Benchmark 能力说明

## 概述

`gateway-benchmark` 是一个推理网关对比测试工具，基于
[llm-d-benchmark](https://github.com/llm-d/llm-d-benchmark) 的 run-only 模式运行，
不依赖重新部署集群，直接对已有的推理 endpoint 发压。

支持同时对 **llm-d** 和 **aibrix** 两个网关进行测试，结果目录结构一致，便于横向对比。

---

## 支持的网关

| 网关 | 入口脚本 | config.yaml 配置节 |
|------|----------|-------------------|
| llm-d（EPP Standalone / Gateway 模式均可） | `run_llmd.sh` | `llmd` |
| aibrix | `run_aibrix.sh` | `aibrix` |

两者均通过统一的 `run.sh --gateway <llmd\|aibrix>` 驱动，配置在 `config.yaml` 中集中管理。

---

## 支持的 Harness

### inference-perf（默认）

基于 [kubernetes-sigs/inference-perf](https://github.com/kubernetes-sigs/inference-perf)，
以恒定 QPS 或阶梯 QPS 向 `/v1/completions` 发压，收集请求级别的延迟指标。

**输出指标：**
- TTFT（Time to First Token）：首 token 延迟，P50/P90/P99
- TPOT（Time per Output Token）：每输出 token 时间，P50/P90/P99
- 端到端请求延迟（E2E latency），P50/P90/P99
- 吞吐量：input tokens/s、output tokens/s、requests/s
- 成功率 / 失败数

**报告格式：**
- `stage_N_lifecycle_metrics.json`：每个阶段的原始指标
- `per_request_lifecycle_metrics.json`：每条请求的详细记录
- `summary_lifecycle_metrics.json`：全量汇总
- `benchmark_report,_*.yaml`（v0.1）和 `benchmark_report_v0.2,_*.yaml`（v0.2）：标准化报告

### guidellm

基于 [guidellm](https://github.com/neuralmagic/guidellm)，支持自动扫描最大吞吐量，
适合探索服务的饱和点。

**输出指标：**
- 最大可持续吞吐量（requests/s、tokens/s）
- TTFT / ITL（Inter-Token Latency）
- 各 rate 点的延迟分布

---

## 支持的 Workload Profiles

### inference-perf

| Profile | 场景 | 负载描述 |
|---------|------|----------|
| `sanity.yaml` | 快速验通 | 1 QPS，30s，小 prompt（256~512 in，10~100 out） |
| `sweep_chatbot.yaml` | 通用对话阶梯压测 | 1→2→4→8 QPS，各 120s，随机 prompt（均值 512 in / 256 out） |
| `sweep_shared_prefix.yaml` | 前缀缓存命中 | 1→2→4→8 QPS，32组×32条共享前缀（system_prompt 512 tokens） |
| `shared_prefix_multi_turn_chat.yaml` | 多轮对话 + 前缀缓存 | 2→3→4→5 QPS，共享 system_prompt + 多轮上下文累积，session 级指标 |
| `code_completion_synthetic.yaml` | 代码补全场景 | 1→2→4→8 QPS，长输入短输出（均值 2048 in / 128 out） |
| `summarization_synthetic.yaml` | 文档摘要场景 | 1→2→4→8 QPS，长输入短输出（均值 2048 in / 128 out） |
| `random_concurrent.yaml` | 极限并发吞吐 | 1/2/4/8 并发，随机 prompt（均值 2048 in / 256 out） |
| `agentic_code_generation.yaml` | Agent 编程多轮 | 5→10→20→30→40 并发，conversation_replay，tool call 延迟模拟 |
| `qwen_coder_trace.yaml` | 真实 Coding 流量回放 | 4 并发 session，weka_trace_replay，200 sessions |

### guidellm

| Profile | 场景 | 负载描述 |
|---------|------|----------|
| `sanity.yaml` | 快速验通 | rate 1，30s |
| `sweep_chatbot.yaml` | 通用对话阶梯压测 | 1→2→4→8 QPS，各 120s，512 in / 256 out |
| `shared_prefix_synthetic.yaml` | 共享前缀场景 | 多阶段 rate sweep，prefix_count=32 |

---

## 支持的 Experiments

Experiment 文件覆盖 profile 中的参数，实现多 treatment 对比（每个 treatment 顺序执行）。

### sanity.yaml

单 treatment，快速验通：1 QPS × 30s。

### concurrency_sweep.yaml

5 个 QPS 梯度，每档 60s：

| Treatment | QPS |
|-----------|-----|
| rate1 | 1 |
| rate4 | 4 |
| rate8 | 8 |
| rate16 | 16 |
| rate32 | 32 |

适合绘制延迟-吞吐量曲线，找到服务的饱和拐点。

### throughput_sweep.yaml

4 个 prompt/output 长度组合，适合测前缀缓存场景下不同 token 长度的影响：

| Treatment | question_len | output_len |
|-----------|-------------|------------|
| qlen256-olen256 | 256 | 256 |
| qlen1024-olen256 | 1024 | 256 |
| qlen256-olen1024 | 256 | 1024 |
| qlen1024-olen1024 | 1024 | 1024 |

配合 `sweep_shared_prefix.yaml` workload 使用，测试不同长度下 KV cache 命中率对延迟的影响。

---

## 典型测试组合

| 目的 | 命令 |
|------|------|
| 快速验通 endpoint 是否可用 | `./run_llmd.sh --workload sanity.yaml --experiment sanity.yaml` |
| 通用性能基线（阶梯并发） | `./run_llmd.sh --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml` |
| 前缀缓存命中率测试 | `./run_llmd.sh --workload sweep_shared_prefix.yaml --experiment throughput_sweep.yaml` |
| 使用 guidellm 测最大吞吐 | `./run_llmd.sh --harness guidellm --workload sweep_chatbot.yaml` |
| 双网关对比（需两条命令） | `./run_llmd.sh ...` + `./run_aibrix.sh ...`（相同参数） |
| 多 harness pod 并行加压 | `./run_llmd.sh --parallelism 4 ...` |

## Tokenizer 使用说明

`inference-perf` harness 需要 tokenizer 来：
1. **生成 prompt**：按 token 数控制输入长度（profile 里的 `mean: 512` 是 token 数，不是字符数）
2. **统计输出长度**：把响应文本转成 token，计算 TPOT（每 token 时间）

### 工作链路

```
profiles/inference-perf/sweep_chatbot.yaml.in
  tokenizer:
    pretrained_model_name_or_path: /requests/tokenizer
                │
                │  harness pod 将 workload-pvc 挂载到 /requests
                ▼
  /requests/tokenizer/          ← 提前 cp 到各节点 /mnt/llmdbench-workload-pvc/tokenizer/
    ├── tokenizer.json          ← 核心词表（最重要）
    ├── tokenizer_config.json   ← tokenizer 类型和特殊 token 配置
    ├── vocab.json              ← token → id 映射
    └── merges.txt              ← BPE 子词合并规则
                │
                ▼
  inference-perf 调用 AutoTokenizer.from_pretrained("/requests/tokenizer")
  完全离线加载，不联网
```

### 准备 tokenizer 文件

只需从模型目录拷贝 4 个文件（不需要模型权重），总大小约 10MB：

```bash
SNAPSHOT=/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/a09a35458c702b33eeacc393d103063234e8bc28

mkdir -p /mnt/llmdbench-workload-pvc/tokenizer
cp $SNAPSHOT/tokenizer.json \
   $SNAPSHOT/tokenizer_config.json \
   $SNAPSHOT/vocab.json \
   $SNAPSHOT/merges.txt \
   /mnt/llmdbench-workload-pvc/tokenizer/

# 同步到所有 worker 节点（hostPath PVC 需要每个节点都有）
for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc/tokenizer"
  scp /mnt/llmdbench-workload-pvc/tokenizer/* root@$node:/mnt/llmdbench-workload-pvc/tokenizer/
done
```

### 换模型时是否需要更换 tokenizer

| 情况 | 是否需要换 |
|------|-----------|
| 同系列不同大小（如 Qwen2.5-7B → Qwen2.5-14B） | ❌ 共用同一 tokenizer |
| 同模型不同路由策略对比 | ❌ 不需要换 |
| 不同架构模型（如 Qwen → Llama） | ✅ 需要换对应 tokenizer |

---



1. **tokenizer 需本地可访问**：`inference-perf` harness 在 K8s pod 内加载 tokenizer，
   需提前将 tokenizer 文件放入 workload PVC（`/requests/tokenizer/`），
   profile 中 `tokenizer.pretrained_model_name_or_path` 填 `/requests/tokenizer`。

2. **集群需要 PV**：harness pod 通过 PVC 传递 workload 数据，集群若无 StorageClass
   需手动预建 hostPath PV，并在所有节点上创建对应目录（多节点集群）。

3. **结果保存在 harness pod 所在节点**：hostPath PVC 的数据写在 pod 调度到的节点上，
   运行完成后需从该节点拷回（或使用共享存储）。

4. **`llm-d-precise-prefix-gw` 与 `llm-d-precise-prefix`**：集群中存在两套部署，
   - `llm-d-precise-prefix`：EPP Standalone 模式，endpoint `precise-prefix-cache-routing-epp`
   - `llm-d-precise-prefix-gw`：EPP + InferenceGateway 模式，endpoint `llm-d-inference-gateway`
   
   测试哪套在 `config.yaml` 的 `endpoint_url` 中指定。
