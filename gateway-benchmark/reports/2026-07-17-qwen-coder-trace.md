# 基准测试记录：Qwen Coder Trace 编码场景真实流量回放

**日期**：2026-07-17  
**模型**：qwen25-7b-instruct（vLLM v0.23.0，8 副本，各 1×H200，max-model-len=32768）  
**网关**：llm-d precise-prefix-cache-routing  
**数据集**：[qwen-bailian-usagetraces-anon](https://github.com/alibaba-edu/qwen-bailian-usagetraces-anon) - qwen_coder_blksz_16.jsonl  
**场景**：代码补全真实生产流量回放，concurrent_sessions=4，num_sessions=200  

## 数据集统计

| 指标 | 数值 |
|------|------|
| 原始记录数 | 43,011 条 |
| 会话数（过滤后） | 298 sessions |
| 平均轮次 | 1.98 轮/session |
| 多轮比例 | 39.9% |
| Input token 均值 | 2,821（原始 5,748，截断到 7680） |
| Output token 均值 | 828 |

## 测试结果

| 指标 | 数值 |
|------|------|
| 总请求数 | 396（200 sessions） |
| 成功/失败 | 396 / 0（**100% 成功**） |
| 测试时长 | 17.8 分钟 |

### 延迟指标

| 指标 | p50 | p90 | p99 |
|------|-----|-----|-----|
| TTFT | **125ms** | 217ms | 318ms |
| TPOT | **4.8ms** | 4.9ms | 5.1ms |
| NTPOT | 5.1ms | 6.2ms | 24.4ms |
| E2E | **2.76s** | 6.85s | 17.69s |

### 吞吐量

| 指标 | 数值 |
|------|------|
| Output tok/s | 259 |
| Input tok/s | 1,050 |
| Total tok/s | 1,309 |
| Req/s | 0.370 |

### Token 分布（真实编码场景）

| 指标 | p50 | p90 |
|------|-----|-----|
| Input token | 2,379 | 5,936 |
| Output token | 539 | 1,388 |

## 与合成数据对比

| 场景 | Input 均值 | Output 均值 | TTFT p50 | E2E p50 |
|------|-----------|------------|---------|---------|
| 合成随机（sweep_chatbot 8 QPS） | ~384 | ~50 | 76ms | 1.37s |
| 合成共享前缀（8 QPS） | ~768 | ~256 | 66ms | 1.32s |
| **真实编码 Trace（4 并发）** | **2,379** | **539** | **125ms** | **2.76s** |

真实编码场景 input token 是合成数据的 6×，TTFT 相应增大约 1.7×，E2E 延迟约 2×，符合预期。

## 备注

- `KV cache 命中率 0.0%`：因 llmdbenchmark 的 `prompt_tokens.cached` 字段未被 vLLM 填充，实际命中率应通过 pod metrics 端点直接采样
- E2E p99 = 17.69s 偏高，原因是 output 最长可达 1388 token（p90），长输出自然会增加 E2E 尾延迟
- 并发仅 4 sessions，GPU 远未饱和（output 259 tok/s vs 峰值 24989 tok/s）

## 复现命令

```bash
cd /root/ai-model-gateway-base/gateway-benchmark
bash run_llmd.sh --workload qwen_coder_trace.yaml
```

数据集路径：`/mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted/`
