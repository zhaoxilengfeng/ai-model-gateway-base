# Gateway Benchmark

对比 llm-d 和 aibrix 两个推理网关在相同条件下的推理性能。基于 [llm-d-benchmark](https://github.com/llm-d/llm-d-benchmark) 的 run-only 模式（`-U <endpoint>`），不需要重新部署集群。

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

结果写入 `results/<gateway>/<harness>/<timestamp>/`，两个网关目录结构一致，便于对比。

## 前置条件

### 1. 安装 llm-d-benchmark

```bash
cd /root/llm-d-benchmark

# 用 uv 创建 Python 3.11 venv 并安装
~/.local/bin/uv venv .venv --python 3.11   # 如未安装 uv: curl -LsSf https://astral.sh/uv/install.sh | sh
~/.local/bin/uv pip install -e .
# 安装 planner 依赖（需要能访问 github，可配置代理）
HTTPS_PROXY=socks5://127.0.0.1:1080 \
  ~/.local/bin/uv pip install "git+https://github.com/llm-d-incubation/llm-d-planner.git@v0.1.0"
```

> `run.sh` 会自动检测并激活 `/root/llm-d-benchmark/.venv`，无需每次手动 source。
> 也可以提前激活：`source /root/llm-d-benchmark/.venv/bin/activate`

### 2. 集群存储（K8s harness pod 模式需要）

llmdbenchmark 在 K8s 集群内起 harness pod，需要一个 PV 来传递 workload 数据。
如果集群没有 StorageClass，手动创建 hostPath PV：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: workload-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Delete
  hostPath:
    path: /tmp/llmdbench-workload
    type: DirectoryOrCreate
EOF
```

> 该 PV 是全局共享的，每次测试结束后 llmdbenchmark 会自动清理对应的 PVC。

### 3. harness 镜像预拉取（可选，加速首次运行）

llmdbenchmark 的 harness pod 使用 `ghcr.io/llm-d/llm-d-benchmark:v0.7.0`。
首次运行时，集群节点需要从 `ghcr.io` 拉取该镜像（约 1-2 分钟，取决于网速）。
若集群内节点已有该镜像则跳过拉取，后续运行速度更快。

## 快速开始

### 1. 编辑 config.yaml

```bash
vi /root/ai-model-gateway-base/gateway-benchmark/config.yaml
```

填写真实值（当前 llm-d precise-prefix 已预填）：

```yaml
llmd:
  endpoint_url: "http://10.109.41.89:80"    # EPP ClusterIP
  model: "qwen25-7b-instruct"               # --served-model-name
  namespace: "llm-d-precise-prefix"

aibrix:
  endpoint_url: "http://<aibrix-gateway-ip>:8080"
  model: "<model-name>"
  namespace: "<namespace>"
```

> `namespace` 是 harness Pod 运行所在的 Kubernetes namespace，需要有创建 Pod 的权限。

### 2. 验证配置（dry-run）

```bash
cd /root/ai-model-gateway-base/gateway-benchmark
./run_llmd.sh --dry-run
```

### 3. 快速验通（sanity）

```bash
./run_llmd.sh --workload sanity.yaml --experiment sanity.yaml
```

30 秒，1 QPS，确认 endpoint 能正常响应。

### 4. 正式对比压测

**阶梯并发扫描（推荐入门）：**

```bash
./run_llmd.sh   --harness inference-perf --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml
./run_aibrix.sh --harness inference-perf --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml
```

依次以 1 / 4 / 8 / 16 / 32 QPS 各跑 60 秒，含 TTFT、TPOT、E2E latency 和吞吐量。

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
  --gateway           llmd | aibrix

可选:
  --harness           inference-perf | guidellm  （默认读 config.yaml defaults.harness）
  --workload          profiles/<harness>/ 下的文件名，可不带 .in 后缀
  --experiment        experiments/ 下的文件名，不传则使用 profile 内置阶梯
  --parallelism       并行 harness pod 数（默认 1）
  --proxy             启用代理，如 socks5h://127.0.0.1:1080（默认不使用）
  --spec              llmdbenchmark --spec 参数（默认 gpu）
  --dry-run           只打印命令，不执行
  --list-profiles     列出所有可用 profiles 后退出
  --list-experiments  列出所有可用 experiments 后退出
```

## 查看结果

每次运行结果保存在 `results/<gateway>/<harness>/<timestamp>/`，包含：

- 渲染后的 profile YAML（可复现此次测试）
- 每请求延迟：TTFT / TPOT / E2E latency（p50、p90、p99）
- 吞吐量：tokens/s、requests/s
- 每个 treatment 的 summary 报告

对比两个网关的同一 experiment：

```bash
diff results/llmd/inference-perf/<ts1>/summary.json \
     results/aibrix/inference-perf/<ts2>/summary.json
```

## 添加自定义 Profile

在 `profiles/<harness>/` 下新建 `.yaml.in` 文件，使用以下占位符：

| 占位符 | 含义 |
|--------|------|
| `REPLACE_ENV_LLMDBENCH_HARNESS_STACK_ENDPOINT_URL` | endpoint URL，由 `--endpoint-url` 注入 |
| `REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL` | 模型名，由 `--model` 注入 |

格式参考 `profiles/inference-perf/sweep_chatbot.yaml.in`。

## 添加自定义 Experiment

在 `experiments/` 下新建 YAML，格式：

```yaml
treatments:
  - name: <treatment-name>
    <dot.notation.key>: <value>   # 覆盖 profile 中对应路径的字段
```

`dot.notation.key` 直接映射到 profile YAML 的嵌套路径，例如：
- `load.stages.0.rate` → `load.stages[0].rate`
- `data.shared_prefix.question_len` → `data.shared_prefix.question_len`
