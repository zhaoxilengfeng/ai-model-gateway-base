# TPM 对比：随机输入 vs 共享前缀输入（precise-prefix-routing）

**日期**：2026-07-17  
**SLO**：TTFT p99 ≤ 1000ms  
**场景**：精准前缀路由（precise-prefix-cache-routing），8×H200，qwen25-7b-instruct  

## 测试参数

| 参数 | 随机输入 | 共享前缀输入 |
|------|---------|------------|
| 数据类型 | random | shared_prefix |
| Input 均值 | 512 token | system=512 + question=512 = 1024 token |
| Output 均值 | 256 token | 256 token |
| 并发阶梯 | 200/300/400/500c | 200/300/400/500c |
| 每阶段请求数 | 400 | 400 |

## 完整数据

### 随机输入

| 并发 | output tok/s | output TPM | total TPM | TTFT p50 | TTFT p99 | 状态 |
|------|-------------|-----------|----------|---------|---------|------|
| 200c | 19,641      | 1,178,448  | 3,364,952 | 152ms   | 568ms   | 正常 |
| 300c | 24,242      | 1,454,513  | 4,097,725 | 174ms   | 844ms   | 正常 |
| 400c | 24,989      | **1,499,362** | **4,221,379** | 200ms | **988ms** | **饱和 ←** |
| 500c | 23,144      | 1,388,632  | 3,995,290 | 207ms   | 1117ms  | 过载 |

### 共享前缀输入（precise-prefix-routing KV cache 命中）

| 并发 | output tok/s | output TPM | total TPM | TTFT p50 | TTFT p99 | 状态 |
|------|-------------|-----------|----------|---------|---------|------|
| 200c | 22,949      | 1,376,921  | 6,849,917 | 249ms   | 609ms   | 正常 |
| 300c | 28,620      | 1,717,225  | 8,558,135 | 247ms   | 651ms   | 正常 |
| 400c | 34,939      | **2,096,361** | **10,408,825** | 260ms | **674ms** | **饱和 ←** |
| 500c | 33,890      | 2,033,374  | 10,111,254 | 273ms  | 798ms   | 饱和 |

## 对比汇总（饱和点 400c）

| 指标 | 随机输入 | 共享前缀 | 提升 |
|------|---------|---------|------|
| 有效峰值 output TPM | **150 万** | **210 万** | **+40%** |
| 有效峰值 total TPM | **420 万** | **1040 万** | **+148%** |
| TTFT p50（饱和点）| 200ms | 260ms | +30% |
| TTFT p99（饱和点）| 988ms | **674ms** | **-32%** |

## 结论

1. **output TPM +40%**：KV cache 命中减少 prefill 计算，GPU decode 时间占比提升，相同 SLO 下可承载更高吞吐
2. **TTFT p99 在共享前缀场景反而更低**：input token 虽然更长（1024 vs 512），但 system_prompt 命中缓存，实际 prefill 量减少，TTFT p99 从 988ms 降至 674ms
3. **total TPM 不适合跨场景对比**：共享前缀的 total TPM 因 input 长度大幅增加（+148%），但这部分 input 大多命中缓存未实际计算，total TPM 会高估共享前缀场景的计算量
4. **结论**：precise-prefix-routing 在共享前缀场景下，相同 SLO 条件下 output TPM 可提升 40%，TTFT 尾延迟反而改善

## 复现命令

```bash
cd /root/ai-model-gateway-base/gateway-benchmark

# 随机输入 TPM 测量
bash measure-tpm.sh --concurrency 200,300,400,500 --requests 400

# 共享前缀 TPM 测量
bash measure-tpm.sh --data-type shared_prefix --concurrency 200,300,400,500 --requests 400
```
