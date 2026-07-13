# Gateway Benchmark

对比 llm-d 和 aibrix 两个推理网关在相同条件下的推理性能。

## 目录结构

```
gateway-benchmark/
├── config.yaml                         # 填写 endpoint、model、namespace
├── profiles/
│   ├── inference-perf/
│   │   ├── sanity.yaml.in              # 快速验通：1 QPS, 30s
│   │   ├── sweep_chatbot.yaml.in       # 阶梯压测：1→2→4→8 QPS，各 120s
│   │   └── sweep_shared_prefix.yaml.in # 前缀缓存场景（测 KV cache 命中率）
│   └── guidellm/
│       ├── sanity.yaml.in
│       └── sweep_chatbot.yaml.in
├── experiments/
│   ├── sanity.yaml                     # 单 treatment，快速验通
│   ├── concurrency_sweep.yaml          # QPS 梯度：1→4→8→16→32
│   └── throughput_sweep.yaml           # 前缀长度矩阵：qlen × olen 全因子
├── run.sh                              # 统一入口（读 config.yaml）
├── run_llmd.sh                         # 快捷脚本，等价于 run.sh --gateway llmd
└── run_aibrix.sh                       # 快捷脚本，等价于 run.sh --gateway aibrix
```

结果写入 `results/<gateway>/<harness>/<timestamp>/`，两个网关的结果目录结构一致，便于对比。

## 快速开始

### 1. 激活 llm-d-benchmark 环境

```bash
source /root/llm-d-benchmark/.venv/bin/activate
```

### 2. 填写 config.yaml

```bash
vi config.yaml
```

将 PLACEHOLDER 替换为真实值：

```yaml
llmd:
  endpoint_url: "http://10.x.x.x:80"
  model: "meta-llama/Llama-3.1-8B"
  namespace: "my-namespace"

aibrix:
  endpoint_url: "http://10.x.x.x:8080"
  model: "meta-llama/Llama-3.1-8B"
  namespace: "my-namespace"
```

> `namespace` 是 harness pod 跑在哪个 Kubernetes namespace，需要有权限在其中创建 Pod。

### 3. 验证配置（dry-run）

```bash
./run_llmd.sh --dry-run
./run_aibrix.sh --dry-run
```

`--dry-run` 只打印命令，不实际提交任何 Pod。

### 4. 快速验通

```bash
./run_llmd.sh   --workload sanity.yaml --experiment sanity.yaml
./run_aibrix.sh --workload sanity.yaml --experiment sanity.yaml
```

30 秒，1 QPS，确认两端 endpoint 都能正常响应。

### 5. 正式对比压测

**阶梯并发扫描（推荐入门）：**

```bash
./run_llmd.sh   --harness inference-perf --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml
./run_aibrix.sh --harness inference-perf --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml
```

依次以 1 / 4 / 8 / 16 / 32 QPS 各跑 60 秒，结果中包含每个 rate 下的 TTFT、TPOT、E2E latency 和吞吐量。

**前缀缓存场景（测 KV cache 命中率）：**

```bash
./run_llmd.sh   --workload sweep_shared_prefix.yaml --experiment throughput_sweep.yaml
./run_aibrix.sh --workload sweep_shared_prefix.yaml --experiment throughput_sweep.yaml
```

**切换为 guidellm harness：**

```bash
./run_llmd.sh   --harness guidellm --workload sweep_chatbot.yaml
./run_aibrix.sh --harness guidellm --workload sweep_chatbot.yaml
```

## run.sh 完整参数说明

```
./run.sh --gateway <llmd|aibrix> [OPTIONS]

必填:
  --gateway       llmd | aibrix

可选:
  --harness       inference-perf | guidellm  （默认读 config.yaml defaults.harness）
  --workload      profiles/<harness>/ 下的文件名，可不带 .in 后缀
  --experiment    experiments/ 下的文件名，不传则使用 profile 内置阶梯
  --parallelism   并行 harness pod 数（默认 1）
  --spec          llmdbenchmark --spec 参数（默认 gpu）
  --dry-run       只打印命令，不执行
```

## 查看结果

每次运行结果保存在 `results/<gateway>/<harness>/<timestamp>/`，包含：

- 渲染后的 profile YAML（可复现）
- 每请求延迟（TTFT / TPOT / E2E latency）
- 吞吐量（tokens/s、requests/s）
- 每 treatment 的 summary 报告

对比两个网关的同一 experiment，直接 diff 两个时间戳目录即可：

```bash
diff results/llmd/inference-perf/<ts1>/summary.json \
     results/aibrix/inference-perf/<ts2>/summary.json
```

## 添加新 Profile

在 `profiles/<harness>/` 下新建 `.yaml.in` 文件，用以下占位符：

| 占位符 | 含义 |
|--------|------|
| `REPLACE_ENV_LLMDBENCH_HARNESS_STACK_ENDPOINT_URL` | endpoint URL，由 `--endpoint-url` 注入 |
| `REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL` | 模型名，由 `--model` 注入 |

格式参考 `profiles/inference-perf/sweep_chatbot.yaml.in`。

## 添加新 Experiment

在 `experiments/` 下新建 YAML，格式：

```yaml
treatments:
  - name: <treatment-name>
    <dot.notation.key>: <value>   # 覆盖 profile 中对应路径的字段
```

`dot.notation.key` 直接映射到 profile YAML 的嵌套路径，例如 `load.stages.0.rate` 对应 `load.stages[0].rate`。
