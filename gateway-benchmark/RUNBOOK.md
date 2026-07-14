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

验证 endpoint 是否正常：

```bash
curl http://10.111.96.40/v1/models
```

---

## 1. 准备 tokenizer

inference-perf harness 需要本地 tokenizer 文件，需提前放到 workload PVC 并同步到所有节点：

```bash
# 从模型目录拷贝 tokenizer 文件（只需 4 个小文件，共约 10MB）
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

---

## 2. 准备 PV（集群无 StorageClass 时）

```bash
# 在所有节点上创建目录
for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc"
done

# 创建 hostPath PV
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

---

## 3. 快速验通

确认 endpoint 可用，约 1 分钟完成：

```bash
cd /root/ai-model-gateway-base/gateway-benchmark

./run_llmd.sh --workload sanity.yaml
```

---

## 4. 标准压测

### 4.1 通用对话阶梯压测（随机负载）

```bash
./run_llmd.sh --workload sweep_chatbot.yaml
```

### 4.2 前缀缓存效果测试

```bash
./run_llmd.sh --workload sweep_shared_prefix.yaml
```

### 4.3 多轮对话 + 前缀缓存（session 级指标）

```bash
./run_llmd.sh --workload shared_prefix_multi_turn_chat.yaml
```

### 4.4 代码补全场景

```bash
./run_llmd.sh --workload code_completion_synthetic.yaml
```

### 4.5 文档摘要场景（长输入短输出）

```bash
./run_llmd.sh --workload summarization_synthetic.yaml
```

### 4.6 Agent 多轮编程场景

```bash
./run_llmd.sh --workload agentic_code_generation.yaml
```

### 4.7 极限并发吞吐（找服务上限）

```bash
./run_llmd.sh --workload random_concurrent.yaml
```

### 4.8 真实 Coding 流量回放

使用 Qwen Bailian 真实代码补全请求的 token 分布（需提前准备数据，见第 6 节）：

```bash
./run_llmd.sh --workload qwen_coder_trace.yaml
```

### 4.8 切换为 guidellm（测最大吞吐）

```bash
./run_llmd.sh --harness guidellm --workload sweep_chatbot.yaml

# guidellm 共享前缀场景
./run_llmd.sh --harness guidellm --workload shared_prefix_synthetic.yaml

# guidellm 快速验通
./run_llmd.sh --harness guidellm --workload sanity.yaml
```

### 4.10 带 monitoring 采集 vLLM 指标

```bash
./run_llmd.sh --workload sweep_shared_prefix.yaml --monitoring --analyze
```

---

## 5. 带 Experiment 的参数矩阵测试

Experiment 会覆盖 profile 参数，依次执行多个 treatment：

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

---

## 6. 准备真实 Coding Trace 数据集

### 6.1 下载 Qwen Coder Trace

```bash
mkdir -p /mnt/llmdbench-workload-pvc/datasets/qwen-coder

https_proxy=socks5h://127.0.0.1:1080 curl -L \
  "https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon/raw/refs/heads/main/qwen_coder_blksz_16.jsonl" \
  -o /mnt/llmdbench-workload-pvc/datasets/qwen-coder/qwen_coder_blksz_16.jsonl
```

### 6.2 转换为 weka_trace_replay 格式

```bash
python3 convert_qwen_trace.py \
  /mnt/llmdbench-workload-pvc/datasets/qwen-coder/qwen_coder_blksz_16.jsonl \
  /mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted \
  --block-size 16

# 同步到所有 worker 节点
for node in 10.0.0.2 10.0.0.4 10.0.0.5; do
  ssh root@$node "mkdir -p /mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted"
  rsync -a /mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted/ \
    root@$node:/mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted/
done
```

---

## 7. 对比两次测试结果

```bash
./compare.sh <结果目录A> <结果目录B> [标签A] [标签B]

# 示例：对比随机 vs 前缀缓存
./compare.sh \
  results/llmd/inference-perf/20260713_203518 \
  results/llmd/inference-perf/20260713_204742 \
  "随机" "共享前缀"
```

查看所有可用结果目录：

```bash
./compare.sh  # 不带参数，列出所有结果
```

---

## 8. 查看测试结果

结果文件保存在 harness pod 所在节点（通常为 host-000-002）的 `/mnt/llmdbench-workload-pvc/` 下：

```bash
# 查看最新测试的结果文件
EXP=$(ssh root@10.0.0.2 "ls /mnt/llmdbench-workload-pvc/ | grep -v tokenizer | grep -v datasets | sort | tail -1")
ssh root@10.0.0.2 "ls /mnt/llmdbench-workload-pvc/$EXP/"

# 查看汇总指标
ssh root@10.0.0.2 "cat /mnt/llmdbench-workload-pvc/$EXP/summary_lifecycle_metrics.json" \
  | python3 -m json.tool

# 拷贝到本地
scp -r root@10.0.0.2:/mnt/llmdbench-workload-pvc/$EXP/ ./results/
```

---

## 9. 其他常用操作

### dry-run（只打印命令，不执行）

```bash
./run_llmd.sh --workload sweep_chatbot.yaml --dry-run
```

### 列出所有可用 profiles

```bash
./run_llmd.sh --list-profiles
```

### 列出所有可用 experiments

```bash
./run_llmd.sh --list-experiments
```

### 多 harness pod 并行加压

```bash
./run_llmd.sh --workload sweep_chatbot.yaml --parallelism 4
```

### 清理残留的 harness 资源

```bash
kubectl delete pods -n llm-d-precise-prefix-gw -l app=llmdbench-harness-launcher
kubectl delete configmap -n llm-d-precise-prefix-gw inference-perf-profiles llmdbench-harness-scripts
kubectl delete pod access-to-harness-data-workload-pvc -n llm-d-precise-prefix-gw
kubectl delete pvc workload-pvc -n llm-d-precise-prefix-gw
```

### 释放 Released 状态的 PV（每次测试后自动执行，也可手动）

```bash
kubectl patch pv llmdbench-workload-pv -p '{"spec":{"claimRef":null}}'
```
