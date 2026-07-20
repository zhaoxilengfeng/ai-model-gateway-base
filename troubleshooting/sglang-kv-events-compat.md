# sglang + llm-d 精准前缀路由：KV events 格式不兼容问题

**状态：已确认根因，待官方修复**  
**测试日期**：2026-07-20  
**环境**：sglang latest, llm-d EPP kv-cache v0.9.0

## 验证结论

sglang 的 KV events **可以发布并被 EPP 接收**，但精准前缀路由**无法正常工作**，原因是 block hash 格式不兼容。

## 问题现象

EPP 日志持续报错：

```
Failed to get request key for parent block
engine key not found: <hash_value>
```

## 根因分析

### 1. ZMQ 帧格式（已兼容）

EPP v0.9.0 期望 3 帧：`[topic] [seq_uint64] [msgpack_payload]`，与 sglang 格式一致。

### 2. Block hash 算法差异（核心问题）

sglang 发出的 BlockStored 事件结构：

```python
['BlockStored', [block_hash_int64], parent_hash_int64, [token_ids], num_tokens, None, 'GPU']
```

关键问题：
- `block_hash`：`list` 类型，包含 **signed int64**，如 `[-3803416546237817494]`
- `parent_hash`：直接 **signed int64**，如 `-1757470295420607631`

EPP 建立索引时用 `block_hash[0]` as uint64 作为 key；查找 parent 时用 `parent_hash` as uint64 查找，但两者的实际数值不匹配（hash 算法本身有差异）。

验证示例：

```
sglang block_hash: [-3803416546237817494] → uint64: 14643327527471734122
EPP parentEngineKey:                                  14643327527471943985  ← 不相等
```

差值约 20 万，说明不是简单的 signed/unsigned 转换问题，而是 hash 函数输入/计算方式不同。

### 3. 影响范围

- sglang 推理：✅ 完全正常
- KV events 发布：✅ 正常发布，EPP 能接收
- 精准前缀路由：❌ 降级为普通负载均衡（EPP 无法建立有效的 prefix index）
- 路由功能本身：✅ 正常，只是没有 prefix 感知

## 解决路径

**待官方修复（推荐）**

需要 sglang 和 llm-d 联合确认 block hash 规范：

- sglang：[sgl-project/sglang #6800](https://github.com/sgl-project/sglang/issues/6800)
- llm-d：提 issue 跟踪兼容性

**临时 workaround（待验证）**

修改 EPP 的 ZMQ subscriber，在解析 sglang block_hash 时做 signed→unsigned 转换。
但实际 hash 值不相等表明 hash 算法本身有差异，不是转换能解决的。

## 测试过的方案

| 方案 | 结果 |
|------|------|
| 去掉 seq_bytes 帧（2帧格式） | ❌ EPP 报 `want=3 got=2`，EPP 已期望3帧 |
| 恢复3帧格式 | ✅ 帧格式匹配，但 hash 不兼容 |
| signed→unsigned 转换 | ❌ 数值仍不匹配，差值≈20万 |

## 当前推荐操作

在官方修复前，直接跑 **vLLM vs sglang 性能对比测试**（不依赖精准前缀路由是否生效）。
sglang 推理功能完全正常，性能数据是有效的。

## 复现步骤

```bash
# 部署 sglang qwen25-7b
bash models/start-qwen25-7b-instruct-sglang.sh

# 查看 EPP 错误
kubectl logs -n llm-d-precise-prefix-gw -l app=precise-prefix-cache-routing-epp --tail=20 | grep 'engine key'

# 抓 sglang ZMQ 事件
kubectl exec <sglang-pod> -n llm-d-precise-prefix-gw -- python3 -c "
import zmq, msgspec, struct
ctx = zmq.Context()
s = ctx.socket(zmq.SUB)
s.connect('tcp://localhost:5556')
s.setsockopt_string(zmq.SUBSCRIBE, 'kv@')
s.setsockopt(zmq.RCVTIMEO, 5000)
m = s.recv_multipart()
print('frames:', len(m))
payload = msgspec.msgpack.decode(m[2])
print('events:', payload[1][:2])  # 前2个事件
"
```
