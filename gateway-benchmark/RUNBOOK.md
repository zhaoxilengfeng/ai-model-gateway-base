# Gateway Benchmark 使用手册

## 0. 一键初始化环境（新用户从这里开始）

```bash
cd /root/ai-model-gateway-base/gateway-benchmark

# 自动创建 PV、同步 tokenizer 到所有节点
bash setup.sh

# 查看可用 profiles / experiments / 历史结果
./run_llmd.sh --list-profiles
./run_llmd.sh --list-experiments
./run_llmd.sh --list-results
```

---

## 1. 前置配置

编辑 `config.yaml`，填写要测试的网关信息：

```yaml
llmd:
  endpoint_url: "http://10.111.96.40:80"      # EPP / InferenceGateway ClusterIP
  model: "qwen25-7b-instruct"                 # vLLM --served-model-name
  namespace: "llm-d-precise-prefix-gw"        # harness pod 运行所在的 namespace

aibrix:
  endpoint_url: "http://<aibrix-ip>:8080"
  model: "<model-name>"
  namespace: "<namespace>"
```

---

## 2. 集群健康检查

测试前先确认集群和推理服务状态正常：

```bash
# 一键检查：Pod 状态 + 模型接口 + 推理请求 + vLLM 指标
./healthcheck.sh

# 检查 aibrix 网关
./healthcheck.sh --gateway aibrix

# 指定 endpoint 检查（不依赖 config.yaml）
./healthcheck.sh --endpoint http://10.111.96.40:80 --model qwen25-7b-instruct
```

**输出包含：**
- K8s Pod 运行状态（Running / Completed / Error）
- `/v1/models` 接口是否正常、模型是否已注册
- 一次真实推理请求（耗时、token 数、模型回复内容）
- vLLM 指标：KV cache 使用率、排队请求数、前缀缓存命中率

---

## 3. 快速验通

集群正常后，用 sanity 做基准测试验通（1 QPS × 30s，约 2 分钟）：

```bash
./run_llmd.sh --workload sanity.yaml
```

验通后查看结果：

```bash
./show.sh   # 自动找最新结果并格式化展示
```

---

## 4. 标准压测

### 4.1 通用对话阶梯压测（随机负载）

1→2→4→8 QPS，各 120s，随机 prompt（均值 512 tokens 输入 / 256 tokens 输出）：

```bash
./run_llmd.sh --workload sweep_chatbot.yaml
```

### 4.2 前缀缓存效果测试

32 组 × 32 条共享 system_prompt，测精确前缀路由的 KV cache 命中收益：

```bash
./run_llmd.sh --workload sweep_shared_prefix.yaml
```

### 4.3 多轮对话 + 前缀缓存（session 级指标）

共享 system_prompt + 多轮上下文累积，采集 session duration、取消率等：

```bash
./run_llmd.sh --workload shared_prefix_multi_turn_chat.yaml
```

### 4.4 代码补全场景

长输入短输出（均值 2048 in / 128 out），模拟代码补全请求特征：

```bash
./run_llmd.sh --workload code_completion_synthetic.yaml
```

### 4.5 文档摘要场景（长输入短输出）

```bash
./run_llmd.sh --workload summarization_synthetic.yaml
```

### 4.6 Agent 多轮编程场景

多轮对话 + tool call 延迟模拟，conversation_replay 模式：

```bash
./run_llmd.sh --workload agentic_code_generation.yaml
```

### 4.7 极限并发吞吐（找服务上限）

并发模式，测服务的最大可持续吞吐：

```bash
./run_llmd.sh --workload random_concurrent.yaml
```

### 4.8 真实 Coding 流量回放

使用 Qwen Bailian 真实代码补全请求的 token 分布（需提前准备数据，见第 7 节）：

```bash
./run_llmd.sh --workload qwen_coder_trace.yaml
```

### 4.9 切换为 guidellm（测最大吞吐）

```bash
# 通用对话
./run_llmd.sh --harness guidellm --workload sweep_chatbot.yaml

# 共享前缀场景
./run_llmd.sh --harness guidellm --workload shared_prefix_synthetic.yaml

# 快速验通
./run_llmd.sh --harness guidellm --workload sanity.yaml
```

### 4.10 带 monitoring 采集 vLLM 指标（推荐与前缀缓存测试配合使用）

开启后会采集 KV cache 命中率、EPP prefix indexer 命中率等指标，并生成分析图表：

```bash
./run_llmd.sh --workload sweep_shared_prefix.yaml --monitoring --analyze
```

---

## 5. Experiment 参数矩阵测试

Experiment 会覆盖 profile 参数，依次执行多个 treatment，最后自动生成对比报告：

### 5.1 并发扫描（找饱和拐点）

5 个 QPS 梯度：1 / 4 / 8 / 16 / 32，各 60s：

```bash
./run_llmd.sh --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml
```

### 5.2 输入输出长度矩阵（前缀缓存场景）

4 种 question_len × output_len 组合：

```bash
./run_llmd.sh --workload sweep_shared_prefix.yaml --experiment throughput_sweep.yaml
```

### 5.3 随机负载 vs 共享前缀对比（一次跑完两种场景）

```bash
./run_llmd.sh --workload sweep_chatbot.yaml \
              --experiment random_vs_shared_prefix.yaml \
              --analyze
```

---

## 6. 查看与对比测试结果

### 格式化展示单次结果

```bash
# 展示最新结果
./show.sh

# 展示指定结果
./show.sh results/llmd/inference-perf/20260713_203518
```

### 列出历史结果

```bash
./run_llmd.sh --list-results
```

### 对比两次测试

```bash
./compare.sh <结果目录A> <结果目录B> [标签A] [标签B]

# 示例：随机 vs 共享前缀
./compare.sh \
  results/llmd/inference-perf/20260713_203518 \
  results/llmd/inference-perf/20260713_204742 \
  "随机" "共享前缀"
```

输出包含各 QPS 阶段的 TTFT / TPOT / ITL / E2E / NTPOT / 吞吐量对比，绿色为改善，红色为恶化。

### 从 worker 节点拉取结果到本地

```bash
EXP=$(ssh root@10.0.0.2 "ls /mnt/llmdbench-workload-pvc/ | grep -v tokenizer | grep -v datasets | sort | tail -1")
scp -r root@10.0.0.2:/mnt/llmdbench-workload-pvc/$EXP/ ./results/
```

---

## 7. 准备真实 Coding Trace 数据集

### 7.1 下载 Qwen Coder Trace

```bash
mkdir -p /mnt/llmdbench-workload-pvc/datasets/qwen-coder

https_proxy=socks5h://127.0.0.1:1080 curl -L \
  "https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon/raw/refs/heads/main/qwen_coder_blksz_16.jsonl" \
  -o /mnt/llmdbench-workload-pvc/datasets/qwen-coder/qwen_coder_blksz_16.jsonl
```

### 7.2 转换为 weka_trace_replay 格式

```bash
python3 convert_qwen_trace.py \
  /mnt/llmdbench-workload-pvc/datasets/qwen-coder/qwen_coder_blksz_16.jsonl \
  /mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted \
  --block-size 16 \
  --max-input-len 7680 \
  --max-model-len 8192

# 同步到所有 worker 节点
for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted"
  rsync -a /mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted/ \
    root@$node:/mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted/
done
```

---

## 8. 其他常用操作

### 预览命令（不执行）

```bash
./run_llmd.sh --workload sweep_chatbot.yaml --dry-run
```

### 多 harness pod 并行加压

```bash
./run_llmd.sh --workload sweep_chatbot.yaml --parallelism 4
```

### 调试模式（harness pod 不退出，可 exec 进去排查）

```bash
./run_llmd.sh --workload sanity.yaml --debug
# 然后: kubectl exec -it -n llm-d-precise-prefix-gw <pod-name> -- bash
```

### 仅收集已有结果（不重跑）

```bash
./run_llmd.sh --workload sweep_chatbot.yaml --skip
```

### 清理残留的 harness 资源

```bash
kubectl delete pods -n llm-d-precise-prefix-gw -l app=llmdbench-harness-launcher
kubectl delete configmap -n llm-d-precise-prefix-gw inference-perf-profiles llmdbench-harness-scripts
kubectl delete pod access-to-harness-data-workload-pvc -n llm-d-precise-prefix-gw
kubectl delete pvc workload-pvc -n llm-d-precise-prefix-gw
```

### 手动释放 Released 状态的 PV

```bash
kubectl patch pv llmdbench-workload-pv -p '{"spec":{"claimRef":null}}'
```

---

## 9. 准备 tokenizer（手动方式）

setup.sh 会自动完成，手动执行方式如下：

```bash
SNAPSHOT=/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct/snapshots/a09a35458c702b33eeacc393d103063234e8bc28

mkdir -p /mnt/llmdbench-workload-pvc/tokenizer
cp $SNAPSHOT/tokenizer.json \
   $SNAPSHOT/tokenizer_config.json \
   $SNAPSHOT/vocab.json \
   $SNAPSHOT/merges.txt \
   /mnt/llmdbench-workload-pvc/tokenizer/

for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc/tokenizer"
  scp /mnt/llmdbench-workload-pvc/tokenizer/* root@$node:/mnt/llmdbench-workload-pvc/tokenizer/
done
```

---

## 10. 准备 PV（手动方式，无 StorageClass 时）

setup.sh 会自动完成，手动执行方式如下：

```bash
for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc"
done

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: llmdbench-workload-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /mnt/llmdbench-workload-pvc
    type: DirectoryOrCreate
EOF
```
