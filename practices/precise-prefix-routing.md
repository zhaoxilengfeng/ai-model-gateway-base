# 精准前缀缓存路由工作原理详解

## 什么是精准前缀缓存路由

精准前缀缓存路由（Precise Prefix Cache Routing）是 llm-d 在 optimized-baseline 基础上引入的高级路由策略。核心思想是：**把相同前缀的请求路由到已经缓存了该前缀 KV 块的 vLLM pod**，避免重复计算，降低 TTFT（首 token 延迟）。

与 optimized-baseline 的启发式前缀估算不同，精准路由通过 **ZMQ 实时 KV 块事件**建立全局精确索引，路由决策基于真实缓存状态而非统计估算。

---

## 整体工作流程

```
请求进入 EPP
     │
     ▼
① token-producer
   调用 render service /v1/completions/render
   prompt 文本  ──►  token_ids = [112720, 100700, 104136, ...]
     │
     ▼
② precise-prefix-cache-producer
   按 block_size=64 切分 token_ids
   block_0: token_ids[0:64]   ──SHA256──► hash_A
   block_1: token_ids[64:128] ──SHA256──► hash_B
   ...
     │
     ▼ 查倒排索引
③ prefix-cache-scorer
   hash_A → {pod_A: 命中3块, pod_B: 命中0块}
   计算各 pod 的前缀命中分数（0.0 ~ 1.0）
     │
     ▼
④ 加权评分（多维）
   最终分 = prefix×3.0 + kv_util×2.0 + queue×2.0 + lru×2.0
     │
     ▼
⑤ 选出最高分的 pod，返回其 IP 给 agentgateway proxy
```

---

## 第一步：tokenize（render service）

EPP 收到请求后，`token-producer` 插件调用 render service 的 `/v1/completions/render` 接口将 prompt 转为 token ID 序列。

### 实测：tokenize 接口

请求：
```bash
curl http://10.101.160.128:8000/v1/completions/render \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","prompt":"请详细解释 Transformer 注意力机制的数学原理，包括 Query Key Value 三个矩阵"}'
```

返回（实测）：
```json
[{
  "request_id": "cmpl-910774326224507f",
  "token_ids": [112720, 100700, 104136, 62379, 93920, 114,
                77835, 15946, 42140, 64355, 35926, 108260,
                100674, 9370, 104552, 105318, 3837, 100630,
                11361, 5309, 5162, 10236, 253, 102, 99854,
                9370, 100768, 75768],
  "model": "qwen25-7b-instruct"
}]
```

上述 prompt 被 tokenize 为 **28 个 token**，按 block_size=64 分为 **1 个块**（不足 64 个 token 为一个不完整块）。

---

## 第二步：按 block_size=64 切分并计算哈希

`precise-prefix-cache-producer` 将 token_ids 序列按 64 个为一组切分，对每组计算 **SHA256** 哈希作为 block key。

```
token_ids = [112720, 100700, 104136, ...]  (28 tokens)

block_0 = token_ids[0:64]     → SHA256 → 0x7f3a8b...  (不满64，作为最后一个块)
block_1 = token_ids[64:128]   → SHA256 → 0x2c91d4...  (如果 prompt 更长)
...
```

**block_size=64 是关键参数**，必须与 vLLM 启动参数 `--block-size=64` 完全一致：

```
# vLLM 实际启动日志（实测）
kv_events_config: KVEventsConfig(
  enable_kv_cache_events=True,
  publisher='zmq',
  endpoint='tcp://*:5556',
  topic='kv@10.244.142.250:8000@qwen25-7b-instruct',
  block_size=64     ← 与 EPP blockSize=64 一致
)
Starting ZMQ publisher thread
```

不一致会导致 EPP 计算的哈希与 vLLM 内部缓存的哈希不匹配，精准路由失效。

---

## 第三步：vLLM 发布 KV 块事件（ZMQ）

每当 vLLM 完成一个请求的 prefill 阶段，它会通过 ZMQ PUB socket（`:5556`）发布 KV 块事件，通知 EPP 哪些 block hash 现在已经缓存在这个 pod 上。

### ZMQ 消息格式（实测抓包）

```
frame[0]: topic  = b"kv@10.244.142.250:8000@qwen25-7b-instruct"
frame[1]: seq_no = <uint64 little-endian>
frame[2]: payload = msgpack({
  "event_type": "BlockStored",
  "block_hash": <bytes>,
  "slot": <int>,
  ...
})
```

topic 格式：`kv@<pod_ip>:<port>@<model_name>`

EPP 配置的 `topicFilter: "kv@"` 匹配所有以 `kv@` 开头的 topic，通过 pod IP 识别是哪个 pod 发来的事件。

### vLLM 端的启动日志确认（实测）

```
# pod: qwen25-7b-instruct-...-4cps4 (host-000-002, IP: 10.244.142.250)
KVEventsConfig(topic='kv@10.244.142.250:8000@qwen25-7b-instruct')
Starting ZMQ publisher thread

# pod: qwen25-7b-instruct-...-stx52 (host-000-005, IP: 10.244.41.130)  
KVEventsConfig(topic='kv@10.244.41.130:8000@qwen25-7b-instruct')
Starting ZMQ publisher thread
```

每个 vLLM pod 各自绑定一个 ZMQ PUB socket，EPP 的每个副本分别订阅所有 pod 的 socket。

---

## 第四步：EPP 订阅 ZMQ 并建立倒排索引

EPP 的 `precise-prefix-cache-producer` 订阅所有 vLLM pod 的 ZMQ PUB socket，收到 `BlockStored` 事件后更新内部的倒排索引：

```
倒排索引结构：
  key:   block_hash（SHA256）
  value: {pod_ip → 该 pod 缓存此 block 的记录}

示例（处理若干请求后）：
  0x7f3a8b... → {10.244.142.250: 已缓存, 10.244.41.130: 未缓存}
  0x2c91d4... → {10.244.142.250: 已缓存, 10.244.41.130: 已缓存}
```

EPP 日志中的 ZMQ 连接（实测）：

```
Connected subscriber socket  endpoint=tcp://10.244.142.250:5556
Connected subscriber socket  endpoint=tcp://10.244.41.130:5556
```

### pod-discovery 机制

EPP 通过 K8s pod reconciler 动态维护订阅列表：

| 事件 | EPP 行为 |
|---|---|
| `kubectl scale` 新增 pod（ADD）| 自动建立新 pod 的 ZMQ 订阅 |
| `kubectl delete pod`（DELETE+ADD）| 自动重连新 IP |
| `kubectl rollout restart`（UPDATE）| ZMQ 断开，需手动重启 EPP |

---

## 第五步：请求到来时的路由决策

当新请求到达时，EPP 执行以下评分：

### prefix-cache-scorer 计算

```python
# 伪代码：EPP 内部 prefix 评分逻辑
for pod in candidate_pods:
    matched_blocks = 0
    total_blocks = len(request_blocks)
    for block_hash in request_blocks:
        if block_hash in index and pod in index[block_hash]:
            matched_blocks += 1
    prefix_score[pod] = matched_blocks / total_blocks  # 0.0 ~ 1.0
```

### 多维加权最终评分

```
final_score = prefix_score     × 3.0   # 精准前缀命中（权重最高）
            + kv_util_score    × 2.0   # KV cache 利用率
            + queue_score      × 2.0   # 请求队列深度
            + no_hit_lru_score × 2.0   # 无命中时 LRU 策略
```

选出 `final_score` 最高的 pod，将其 IP 返回给 agentgateway proxy。

### 路由决策的实测证明

通过对比测试验证（实测数据）：

```
─── 轮1：随机路由（不同 prompt） ───
  host-000-005: 5/8 条 (62%)  ██████████████████░░░░
  host-000-002: 3/8 条 (38%)  ███████████░░░░░░░░░░░
  最大集中度: 62%

─── 轮2：精准前缀路由（相同 prompt）───
  host-000-002: 7/7 条 (100%) ██████████████████████████████
  host-000-005: 0/7 条 (0%)   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  最大集中度: 100%
```

相同前缀的请求 100% 被路由到同一个 pod（有 KV cache），随机请求则近似均匀分布，差异达 **38 个百分点**，证明精准路由在驱动决策。

---

## 降级机制

当精准路由组件不可用时，系统自动降级，推理请求不中断：

| 故障场景 | 影响 | 降级行为 |
|---|---|---|
| render service 挂掉 | token-producer 无法 tokenize | prefix-cache-scorer score=0，回退到 queue+kv-util 路由 |
| EPP ZMQ 断开（rollout restart）| 索引停止更新 | prefix-cache-scorer score=0，回退到负载感知路由 |
| 单个 vLLM pod 不可达 | 该 pod 的 KV 事件停止 | 其他 pod 正常，EPP 只选可用 pod |

EPP 日志中的降级特征：

```
PrefixCacheMatchInfo not found for endpoint, assigning score 0
```

---

## 关键配置约束

### 三处模型名必须完全一致

```
render  --served-model-name=qwen25-7b-instruct
             ↕
EPP     token-producer.modelName=qwen25-7b-instruct
             ↕
vLLM    --served-model-name=qwen25-7b-instruct
```

任一不一致，render 返回 404，精准路由失效。

### block_size 必须一致

```
vLLM   --block-size=64
            ↕
EPP    tokenProcessorConfig.blockSize=64
```

不一致会导致哈希不匹配，索引建立但永远 score=0。

### vLLM topic 格式必须包含真实 pod IP

```bash
# deploy-model.sh 中的关键配置
--kv-events-config '{"enable_kv_cache_events":true,"publisher":"zmq",
  "endpoint":"tcp://*:5556",
  "topic":"kv@$(POD_IP):8000@qwen25-7b-instruct"}'

# 同时注入环境变量让 vLLM 可以展开 $(POD_IP)
env:
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
```

vLLM 在启动时会展开 `$(POD_IP)` 为实际 pod IP（实测确认），EPP 通过 topic 中的 IP 识别是哪个 pod 发来的事件。

---

## 与 optimized-baseline 路由的对比

| 维度 | optimized-baseline | precise-prefix-cache-routing |
|---|---|---|
| 前缀缓存感知方式 | 启发式（基于历史调度统计估算）| 精准（基于实时 ZMQ KV 块事件）|
| 路由精度 | 近似 | 精确到 block 级别 |
| 额外组件 | 无 | ZMQ（vLLM 侧）+ render service + EPP 倒排索引 |
| 适合场景 | 通用生产环境 | 高重复前缀（RAG、固定 system prompt、多轮对话）|
| 启动开销 | 低 | 略高（需等 KV 事件积累后索引才有效）|
