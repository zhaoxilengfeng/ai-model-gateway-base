# llm-d 精准前缀哈希路由（Precise Prefix Cache Routing）

基于官方 [precise-prefix-cache-routing](https://github.com/llm-d/llm-d/tree/v0.8.1/guides/precise-prefix-cache-routing) 指南，在 optimized-baseline 基础上引入**精准 KV 块哈希路由**，将推理请求路由到前缀缓存命中率最高的 vLLM pod，降低 TTFT（首 token 延迟）。

---

## 与 optimized-baseline 的核心差异

| 特性 | optimized-baseline | precise-prefix-cache-routing |
|---|---|---|
| 前缀缓存感知 | 启发式（基于流量统计估算）| **精准**（基于 KV 块实际哈希值）|
| vLLM KV 事件 | 不启用 | `--kv-events-config` via **ZMQ TCP :5556** |
| block-size | 默认 | **必须 `--block-size=64`**（须与 EPP 一致）|
| EPP 额外组件 | 无 | `precise-prefix-cache-producer` + `token-producer` |
| Tokenizer | 无 | 独立 **render Service**（CPU-only vLLM，3 副本）|
| 路由模式 | Standalone / Gateway | **Standalone**（EPP + Envoy sidecar）|
| EPP 副本 | 1 | 2（active-active HA，双副本各自订阅所有 vLLM pod）|

---

## 工作原理

```
vLLM pod                    EPP (precise-prefix-cache-producer)
  │                               │
  │  ── ZMQ PUB tcp://*:5556 ──►  │  SUB 订阅每个 pod（pod-discovery）
  │  KV 块事件：                   │
  │  topic: kv@<pod-ip>:8000@model │  按 block hash 构建倒排索引
  │  payload: {block_hash, slot}   │  key: hash → value: {pod, 命中数}
                                   │
请求到来时：
  1. token-producer 调用 render Service 将 prompt tokenize
  2. 按 block-size=64 切分为 token block，计算每个块的 hash
  3. 在索引中查找每个候选 pod 命中的块数 → 前缀命中分数
  4. 加权评分（prefix-cache × 3 + kv-util × 2 + queue × 2 + lru × 2）
  5. 路由到得分最高的 pod，直接命中已有 KV cache
```

---

## 组件架构

```
Client
  │
  ▼
EPP svc（ClusterIP）    ← Standalone 模式，EPP 内置 Envoy sidecar
  │
  ▼
EPP pod × 2            ← active-active HA，各自独立订阅 ZMQ
  │  precise-prefix-cache-producer（ZMQ SUB）
  │  token-producer（HTTP → render:8000）
  ▼
render svc / pod × 3   ← CPU-only vLLM，仅做 tokenize，不加载模型权重
  │  vllm launch render
  │
  ▼（路由决策）
vLLM pod × N           ← 每个 pod ZMQ PUB :5556，发布实时 KV 块事件
  │  --block-size=64
  │  --kv-events-config (ZMQ)
  │  --enable-prefix-caching
  ▼
GPU 推理
```

---

## 部署流程

```bash
# 1. 下载 Helm chart 和 CRDs
bash prepare.sh

# 2. 拉取镜像（新增 CPU-only vLLM 用于 render service）
bash downlowd-image.sh

# 3. 安装 EPP + render service
bash install.sh

# 4. 部署模型（自动配置 ZMQ kv-events）
bash deploy-model.sh
```

---

## 注意事项

### block-size 必须一致

vLLM 的 `--block-size` 必须与 EPP 配置中的 `tokenProcessorConfig.blockSize` 保持一致，两者均为 **64**。不一致会导致哈希不匹配，精准路由失效退化为随机路由。

### ZMQ 端口（:5556）

每个 vLLM pod 在 `tcp://*:5556` 绑定一个 ZMQ PUB socket。EPP 通过 pod-discovery 自动发现 pod IP，逐一建立 SUB 连接。确保 K8s NetworkPolicy 不封禁 pod 间 5556/TCP 流量。

### render Service

render pod 使用 `vllm/vllm-openai-cpu:v0.23.0`（CPU-only 镜像），运行 `vllm launch render` 仅做 tokenize，**不加载模型权重，不需要 GPU**。

> **重要**：render 的模型参数必须传**本地 snapshot 绝对路径**，并挂载 hostPath，设置 `HF_HUB_OFFLINE=1`。
>
> 如果传 HuggingFace 模型 ID（如 `Qwen/Qwen3-32B`），vLLM 会尝试联网下载 tokenizer 文件，在离线环境中必然失败（`LocalEntryNotFoundError`）。
>
> `install.sh` 已自动解析本地 snapshot 路径，与 `deploy-model.sh` 保持一致。

render service 名（`${GUIDE_NAME}-render`）须与 EPP `token-producer.vllm.url` 配置一致。

### SERVED_MODEL 与 topic 对应

vLLM KV 事件 topic 格式为 `kv@<pod-ip>:8000@<model-name>`，EPP 通过 `topicFilter: "kv@"` 过滤并解析 topic 中的模型名来做 index 隔离（多模型共存时有效）。

### GPU 驱动要求

同 gateway 模式，vLLM v0.23.0 需要宿主机 NVIDIA 驱动 ≥ 580（CUDA 13.0）。

---

## 访问方式

Standalone 模式通过 EPP 的 ClusterIP 访问（集群内）：

```bash
EPP_IP=$(kubectl get svc precise-prefix-cache-routing-epp \
  -n llm-d-precise-prefix -o jsonpath='{.spec.clusterIP}')

curl http://${EPP_IP}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```

或运行测试脚本：

```bash
bash test-llmd.sh
```

---

## 性能基准测试

部署完成后可使用 `gateway-benchmark` 对该网关进行推理性能测试：

```bash
cd /root/ai-model-gateway-base/gateway-benchmark

# 快速验通（30s）
./run_llmd.sh --workload sanity.yaml --experiment sanity.yaml

# 阶梯并发压测（1→4→8→16→32 QPS）
./run_llmd.sh --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml

# 前缀缓存场景（测 KV cache 命中率，适合 precise-prefix 模式）
./run_llmd.sh --workload sweep_shared_prefix.yaml --experiment throughput_sweep.yaml
```

`config.yaml` 中 `llmd` 部分已预填该部署的 EPP endpoint 和模型名，无需额外配置。
详见 [gateway-benchmark/README.md](../../gateway-benchmark/README.md)。
