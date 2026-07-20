# sglang + llm-d 精准前缀路由：根节点 hash 不兼容问题

**状态：根因完全确认，需 EPP 代码修复**  
**测试日期**：2026-07-20  
**环境**：sglang latest (v0.4.7+), llm-d EPP/kv-cache v0.9.0

## 问题现象

EPP 日志持续报错：

```
Failed to get request key for parent block
engine key not found: <hash_value>
```

## 完整排查过程

### Step 1：帧格式（已兼容）

EPP v0.9.0 期望 3 帧：`[topic] [seq_uint64] [msgpack_payload]`，与 sglang 一致。✅

### Step 2：sglang adapter（已支持）

EPP v0.9.0 内置了 `SGLangAdapter`，配置 `engineType: "sglang"` 后会使用正确的解析器。✅

### Step 3：根因 —— 根节点 parent_hash 不为 0

EPP 的 `pool.go` 逻辑（第 351-359 行）：

```go
parentRequestKey := kvblock.EmptyBlockHash
if ev.ParentHash != 0 {
    // 查找 parent 的 engine key → request key 映射
    key, err := p.index.GetRequestKey(ctx, parentEngineKey)
    if err != nil {
        // 找不到就跳过，不存入索引 ← 问题在这里
        continue
    }
}
```

EPP 期望：**根 block（第一个 block）的 parent_hash == 0**

sglang 实际发出：**根 block 的 parent_hash = SHA256("") 的前 64 位 = `-2039914840885289964`（非零）**

sglang 的 `hash_str_to_int64` 函数：

```python
def hash_str_to_int64(hash_str: str) -> int:
    uint64_val = int(hash_str[:16], 16)
    if uint64_val >= 2**63:
        return uint64_val - 2**64  # ← 转为 signed
    return uint64_val

# 空序列的 SHA256 = "e3b0c44298fc1c14..."
# hash_str_to_int64("e3b0c44298fc1c14") = -2039914840885289964
```

vLLM 的 Python `hash()` 对 `(None, *[])` 返回某个整数，但 EPP 在 vLLM 路径下用的是不同的"根"逻辑（token-producer 生成 canonical keys，不依赖 engine key 为 0）。

### 验证数据

```
sglang 根节点：
  parent_hash = -2039914840885289964  (uint64: 16406829232824261652)

sglang 第一个 block：
  block_hash  = [-6809153640092533380]
  parent_hash = -8914888239034362896  ← EPP 查不到这个 parent，跳过

由于根 block 被跳过，后续所有 block 的 parent 也找不到，全部跳过
→ EPP prefix index 为空 → 精准路由无法工作
```

## 修复方案

**方案一（推荐）：EPP 修复 pool.go**

在 `processEventBatch` 里，当 `engineType == "sglang"` 时，把 sglang 的根节点 hash 值视为 `EmptyBlockHash`：

```go
// sglang 根节点的 parent_hash = SHA256("") 前64位的 signed int64
const sglangRootParentHash = uint64(16406829232824261652)  // -2039914840885289964

parentRequestKey := kvblock.EmptyBlockHash
if ev.ParentHash != 0 && !(engineType == "sglang" && ev.ParentHash == sglangRootParentHash) {
    // 正常查找
}
```

提 issue：https://github.com/llm-d/llm-d-kv-cache/issues

**方案二：修改 sglang，根节点 parent_hash 输出 0**

修改 `sglang/srt/mem_cache/events.py`，当 parent 是根节点时，发出 `parent_block_hash = 0`：

```python
if node.parent is None or node.parent.hash_value is None or len(node.parent.hash_value) == 0:
    parent_block_hash = 0  # 根节点用 0，与 EPP 期望一致
else:
    parent_block_hash = hash_str_to_int64(node.parent.hash_value[-1])
```

提 PR：https://github.com/sgl-project/sglang

## 当前配置

已配置 `engineType: sglang`（EPP configmap），格式解析正确。
仅剩根节点 hash 处理逻辑需修复。

## EPP configmap 当前状态

```yaml
kvEventsConfig:
  topicFilter: "kv@"
  engineType: "sglang"   ← 已配置
  concurrency: 8
  discoverPods: true
  podDiscoveryConfig:
    socketPort: 5556
```
