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
   按 block_size=64 切分 token_ids，链式计算 block hash
   block_0: SHA256(token_ids[0:64])            → hash_A
   block_1: SHA256(hash_A + token_ids[64:128]) → hash_B  ← 含父 hash
   ...
     │
     ▼ 查两层 LRU 索引
③ prefix-cache-scorer
   找每个 pod 已缓存的最长连续前缀块数
   Pod A: B0✓ B1✓ B2✓ B3✗ → 命中 3 块
   Pod B: B0✓ B1✗ --- --- → 命中 1 块（B1 断链，后续不计）
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

## 第二步：切分 token 块并计算链式哈希

`precise-prefix-cache-producer` 将 token_ids 序列按 64 个为一组切分，对每组计算哈希作为 block key。

### 链式哈希（非简单 SHA256）

block hash **不是**单纯对 token_ids 做 SHA256，而是**链式计算**——每个块的 hash 包含父块的 hash：

```
block_0_hash = SHA256(token_ids[0:64])
block_1_hash = SHA256(parent=block_0_hash  ‖  token_ids[64:128])
block_2_hash = SHA256(parent=block_1_hash  ‖  token_ids[128:192])
...
```

**为什么是链式**：KV cache 具有因果依赖性，block_1 的 attention 计算依赖于 block_0 的 KV 状态，因此 block_1 的 hash 必须包含 block_0 的内容。这样设计确保：
- 相同 block_1 内容但 block_0 不同的两个请求，产生不同的 block_1_hash，不会误命中
- 前缀完全相同的两个请求，产生完全相同的 block hash 链，可以精准命中

**block_size=64 必须与 vLLM 一致**，vLLM 实际启动日志（实测）：

```
kv_events_config: KVEventsConfig(
  enable_kv_cache_events=True,
  publisher='zmq',
  endpoint='tcp://*:5556',
  topic='kv@10.244.142.250:8000@qwen25-7b-instruct',
  block_size=64     ← 与 EPP tokenProcessorConfig.blockSize=64 一致
)
Starting ZMQ publisher thread
```

---

## 第三步：vLLM 发布 KV 块事件（ZMQ）

每当 vLLM 完成一个请求的 prefill 阶段，它会通过 ZMQ PUB socket（`:5556`）向 EPP 发布 KV 块事件。

### 三种事件类型

| 事件 | 触发时机 | EPP 行为 |
|---|---|---|
| `BlockStored` | prefill 完成，KV 块写入 cache | 将 block_hash → pod 写入索引 |
| `BlockRemoved` | KV 块因内存压力被 LRU 驱逐 | 从索引中删除该 pod 对此 hash 的记录 |
| `AllBlocksCleared` | pod 整体 cache 清空（如 RL 权重热更新）| 清除该 pod 在索引中的所有记录 |

### ZMQ 消息格式（实测抓包）

```
frame[0]: topic   = b"kv@10.244.142.250:8000@qwen25-7b-instruct"
frame[1]: seq_no  = <uint64 little-endian，单调递增>
frame[2]: payload = msgpack({
  "event_type": "BlockStored",
  "block_hash":  <bytes，链式哈希值>,
  "parent_hash": <bytes，父块哈希>,
  "token_ids":   <list[int]，该块的 token 序列>,
  "slot":        <int，在 vLLM KV cache 中的物理位置>,
  ...
})
```

topic 格式 `kv@<pod_ip>:<port>@<model_name>` 让 EPP 通过 topic 直接识别是哪个 pod 的事件，无需解包 payload。

### vLLM 端确认（实测）

```
pod: qwen25-7b-instruct-...-4cps4 (host-000-002, 10.244.142.250)
  KVEventsConfig(topic='kv@10.244.142.250:8000@qwen25-7b-instruct')
  Starting ZMQ publisher thread  ← 每个 pod 各自的 PUB socket

pod: qwen25-7b-instruct-...-stx52 (host-000-005, 10.244.41.130)
  KVEventsConfig(topic='kv@10.244.41.130:8000@qwen25-7b-instruct')
  Starting ZMQ publisher thread
```

---

## 第四步：EPP 建立 KV 块索引

### 索引的数据结构

EPP 内部维护一个**两层 LRU 内存索引**（来自官方设计文档）：

```
外层 LRU（按 block_hash 查询）：
  key:   block_hash（链式 SHA256）
  value: 内层 LRU

内层 LRU（按 pod 查询）：
  key:   pod_ip
  value: {tier: "gpu"/"cpu", timestamp, ...}

默认容量：最多 1 亿个 block_hash × 10 个 pod 条目
内存占用：约 几十 GB（per EPP 副本）
```

示例（处理若干请求后的索引状态）：

```
block_hash_A → { 10.244.142.250: {tier: gpu, ts: T1},
                  10.244.41.130:  <未缓存> }

block_hash_B → { 10.244.142.250: {tier: gpu, ts: T1},
                  10.244.41.130:  {tier: gpu, ts: T2} }

block_hash_C → { 10.244.41.130:  {tier: gpu, ts: T3} }
```

### 索引的动态维护（增量更新，非全量重算）

EPP 索引是**持久化的内存结构，事件驱动增量更新**。vLLM 只上报变化的块，不重复上报已有缓存：

| 事件 | 触发时机 | 索引操作 |
|---|---|---|
| `BlockStored(hash, pod)` | prefill 完成，新增 KV 块 | `index[hash][pod] = {tier, ts}` |
| `BlockRemoved(hash, pod)` | LRU 驱逐，块被淘汰 | `index[hash].pop(pod)` |
| `AllBlocksCleared(pod)` | cache 整体清空 | 遍历索引，删除该 pod 所有条目 |

**匹配计算只在请求到来时触发一次**，对当前索引快照做查询，时间复杂度 O(块数 × pod数)，非常轻量。

时序示意：

```
vLLM pod A                         EPP 索引（持久存在于内存）
   │                                    │
   ├─ BlockStored(B0, B1, B2) ─────────►│  index[B0][A]=gpu
   │  （prefill 完成，新增3块）          │  index[B1][A]=gpu
   │                                    │  index[B2][A]=gpu
   │
   │   ← 请求1到来（前缀包含 B0,B1,B2）
   │                                    ├─ 查 index：B0✓ B1✓ B2✓ → score=1.0 → 路由到 A
   │
   ├─ BlockStored(B3) ─────────────────►│  index[B3][A]=gpu （只上报新增的 B3）
   │
   ├─ BlockRemoved(B0) ────────────────►│  index[B0].pop(A) （LRU 驱逐 B0）
   │
   │   ← 请求2到来（相同前缀）
   │                                    ├─ 查 index：B0✗ → 连续前缀断链 → score=0
```

**关键点**：vLLM 不会把所有已缓存块全量重发，只在状态变化时推送增量事件。EPP 维护的是一张实时同步的"哪个 pod 缓存了哪些块"的镜像，请求到来时直接查表，不重新计算任何东西。

### 两种 ZMQ 连接模式

当前使用 **pod-discovery 模式**（`discoverPods: true`）：EPP 通过 K8s label selector 发现所有 vLLM pod，主动向每个 pod 建立 SUB 连接。适用于 EPP 多副本 HA——每个副本独立订阅完整事件流，各自维护相同的索引。

```
EPP Replica 1 ──ZMQ SUB──► vLLM Pod A :5556
EPP Replica 1 ──ZMQ SUB──► vLLM Pod B :5556

EPP Replica 2 ──ZMQ SUB──► vLLM Pod A :5556
EPP Replica 2 ──ZMQ SUB──► vLLM Pod B :5556
```

两个副本的索引独立但内容相同，任一副本故障，另一个继续精准路由。

EPP 日志中的连接记录（实测）：
```
Connected subscriber socket  endpoint=tcp://10.244.142.250:5556
Connected subscriber socket  endpoint=tcp://10.244.41.130:5556
```

### pod-discovery 对扩缩容的影响

| 操作 | K8s 事件 | EPP 行为 |
|---|---|---|
| `kubectl scale` 扩容 | ADD | 自动发现新 pod，自动建立 ZMQ 订阅 |
| `kubectl delete pod`（Deployment 重建）| DELETE + ADD | 旧连接清理，新 pod ADD 时自动重建 |
| `kubectl rollout restart` | UPDATE（同 name，IP 变）| ZMQ 断开，需手动重启 EPP |

---

## 第五步：请求到来时的路由决策

### 连续前缀匹配原则（关键）

KV cache 具有因果依赖性——**只有缓存了完整的连续前缀，后续块才能被复用**，中间断链的块无法使用。

```
请求的 block 序列：[B0, B1, B2, B3, B4]

Pod A: B0✓  B1✓  B2✓  B3✓  B4✗  → 命中长度 = 4（连续到 B3）
Pod B: B0✓  B1✓  B2✗  ---  ---  → 命中长度 = 2（B2 断链，B3/B4 不计）
Pod C: B0✗  ---  ---  ---  ---  → 命中长度 = 0

注意：Pod C 即使碰巧缓存了 B3 和 B4，命中长度仍为 0，
      因为 attention 计算必须从 B0 开始连续进行。
```

### 分层缓存权重

当 KV 块缓存在不同内存层时，命中权重不同：

| 缓存层 | 权重 | 说明 |
|---|---|---|
| GPU HBM | 1.0 | 直接复用，无搬运开销 |
| CPU 内存 | 0.8 | 需搬运到 GPU，但仍比重新计算快 |

同一块在多层都有缓存时取最大权重（GPU 优先）。

### prefix-cache-scorer 计算逻辑

```python
# 伪代码（基于官方设计文档）
for pod in candidate_pods:
    score = 0.0
    for i, block_hash in enumerate(request_blocks):
        if block_hash in index and pod in index[block_hash]:
            tier = index[block_hash][pod].tier
            score += tier_weight[tier]   # gpu=1.0, cpu=0.8
        else:
            break   # 链断，后续块不计
    # 归一化到 [0.0, 1.0]
    prefix_score[pod] = score / len(request_blocks)
```

### 推测索引（Speculative Indexing）

**问题**：`BlockStored` 事件在 prefill 完成后通过 ZMQ 异步发送，有毫秒级延迟。若第二个相同前缀的请求在事件到达前就进入 EPP，索引还没有更新，路由会随机分配，破坏前缀亲和性。

**解决方案**：`speculativeIndexing: true`（当前配置已启用）

路由决策完成后，EPP 立即在索引中预写"推测条目"，TTL 默认 2 秒：

```
第1次请求 → 路由到 Pod A
  └── 推测索引写入（TTL 2s）：
        block_hash_A → Pod A（predicted）
        block_hash_B → Pod A（predicted）

第2次请求（50ms 后，BlockStored 尚未到达）
  └── 查推测索引：命中 Pod A
  └── 路由到 Pod A  ← 正确！保持了前缀亲和性

BlockStored 事件到达（200ms 后）
  └── 正式索引覆盖推测索引（confirmed）
```

TTL 2 秒设计目的：足够覆盖典型的 routing-to-event 延迟（< 500ms），同时不会让失败的预测条目长期污染索引。

### 多维加权最终评分

```
final_score = prefix_score     × 3.0   # 精准前缀命中（权重最高，决定路由倾向）
            + kv_util_score    × 2.0   # KV cache 利用率低 → 高分
            + queue_score      × 2.0   # 请求队列短 → 高分
            + no_hit_lru_score × 2.0   # 无命中时 LRU 均衡策略
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

相同前缀的请求 100% 被路由到同一 pod，随机请求近似均匀分布，差异 **38 个百分点**，证明精准路由在驱动决策。

---

## 降级机制

当精准路由组件不可用时，系统自动降级，推理请求不中断：

| 故障场景 | 影响 | 降级行为 |
|---|---|---|
| render service 挂掉 | token-producer 无法 tokenize | prefix-cache-scorer score=0，回退到 queue+kv-util |
| EPP ZMQ 断开（rollout restart）| 索引停止更新 | prefix-cache-scorer score=0，回退到负载感知路由 |
| 单个 vLLM pod 不可达 | 该 pod KV 事件停止 | 其他 pod 正常，EPP 只选可用 pod |

EPP 日志中的降级特征：

```
PrefixCacheMatchInfo not found for endpoint, assigning score 0
```

---

## 关键配置约束

### 三处模型名必须完全一致

```
render  --served-model-name=qwen25-7b-instruct
             ↕ 必须一致
EPP     token-producer.modelName=qwen25-7b-instruct
             ↕ 必须一致
vLLM    --served-model-name=qwen25-7b-instruct
```

### block_size 必须一致

```
vLLM   --block-size=64
            ↕ 必须一致
EPP    tokenProcessorConfig.blockSize=64
```

不一致导致哈希不匹配，索引建立但永远 score=0（静默失效）。

### vLLM topic 格式必须包含真实 pod IP

```bash
--kv-events-config '{"enable_kv_cache_events":true,"publisher":"zmq",
  "endpoint":"tcp://*:5556",
  "topic":"kv@$(POD_IP):8000@qwen25-7b-instruct"}'

env:
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP    # K8s downward API 注入真实 pod IP
```

vLLM 启动时展开 `$(POD_IP)` 为实际 pod IP（实测确认）。

---

## 与 optimized-baseline 路由的对比

| 维度 | optimized-baseline | precise-prefix-cache-routing |
|---|---|---|
| 前缀感知方式 | 启发式（字符/历史统计估算）| 精准（实时 ZMQ KV 块事件）|
| 哈希计算 | 基于字符近似 | 基于真实 token_ids，链式 SHA256 |
| 匹配规则 | 近似命中数 | 连续前缀最长匹配，中断即停 |
| 缓存驱逐感知 | 不感知（可能路由到已驱逐 cache 的 pod）| 实时感知（BlockRemoved 事件更新索引）|
| 额外组件 | 无 | render service + ZMQ + 两层 LRU 索引 |
| 适合场景 | 通用生产环境 | RAG、固定 system prompt、多轮对话 |
