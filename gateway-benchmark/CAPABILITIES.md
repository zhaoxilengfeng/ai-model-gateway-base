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
| `sanity.yaml` | 快速验通 | 1 QPS，30s，小 prompt（256~512 tokens in，10~100 tokens out） |
| `sweep_chatbot.yaml` | 通用聊天场景阶梯压测 | 1→2→4→8 QPS，各 120s，随机 prompt（均值 4096 in / 1024 out） |
| `sweep_shared_prefix.yaml` | 前缀缓存命中场景 | 1→2→4→8 QPS，各 120s，32 组 × 32 条共享前缀请求（system_prompt 2048 tokens） |

### guidellm

| Profile | 场景 | 负载描述 |
|---------|------|----------|
| `sanity.yaml` | 快速验通 | rate 1，30s |
| `sweep_chatbot.yaml` | 通用聊天阶梯压测 | 1→2→4→8 QPS，各 120s，4096 in / 1024 out |

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

---

## 已知注意事项

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
