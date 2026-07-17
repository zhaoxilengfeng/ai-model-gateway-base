# 基准测试记录：qwen25-7b-instruct sweep_shared_prefix

**日期**：2026-07-17  
**模型**：qwen25-7b-instruct（vLLM v0.23.0，8 副本，各 1×H200）  
**网关**：llm-d precise-prefix-cache-routing  
**测试**：sweep_shared_prefix + throughput_sweep（4 种 qlen×olen 组合，各跑 1/2/4/8 QPS）  
**场景**：32 组 × 32 条共享 system_prompt（512 token），测 KV cache prefix 命中收益  

## 结果汇总

### qlen256-olen256（短问短答）

| QPS | 成功/失败 | output tok/s | TTFT p50 | TTFT p90 | E2E p50 |
|-----|-----------|-------------|----------|----------|---------|
| 1   | 120 / 0   | 256         | 79ms     | 226ms    | 1331ms  |
| 2   | 240 / 0   | 507         | 65ms     | 79ms     | 1312ms  |
| 4   | 480 / 0   | 1010        | 64ms     | 80ms     | 1312ms  |
| 8   | 960 / 0   | 2051        | **66ms** | 82ms     | 1324ms  |

### qlen1024-olen256（长问短答）

| QPS | 成功/失败 | output tok/s | TTFT p50 | TTFT p90 | E2E p50 |
|-----|-----------|-------------|----------|----------|---------|
| 1   | 120 / 0   | 267         | 117ms    | 150ms    | 1375ms  |
| 2   | 240 / 0   | 530         | 96ms     | 120ms    | 1350ms  |
| 4   | 480 / 0   | 1085        | 94ms     | 116ms    | 1355ms  |
| 8   | 960 / 0   | 2122        | **96ms** | 116ms    | 1372ms  |

### qlen256-olen1024（短问长答）

| QPS | 成功/失败 | output tok/s | TTFT p50 | TTFT p90 | E2E p50 |
|-----|-----------|-------------|----------|----------|---------|
| 1   | 120 / 0   | 1009        | 81ms     | 104ms    | 5062ms  |
| 2   | 240 / 0   | 1973        | 74ms     | 92ms     | 5102ms  |
| 4   | 480 / 0   | 3931        | 75ms     | 91ms     | 5169ms  |
| 8   | 960 / 0   | **7843**    | **74ms** | 92ms     | 5262ms  |

### qlen1024-olen1024（长问长答）

| QPS | 成功/失败 | output tok/s | TTFT p50 | TTFT p90 | E2E p50 |
|-----|-----------|-------------|----------|----------|---------|
| 1   | 120 / 0   | 1009        | 120ms    | 149ms    | 5127ms  |
| 2   | 240 / 0   | 1999        | 103ms    | 128ms    | 5155ms  |
| 4   | 480 / 0   | 4010        | 104ms    | 129ms    | 5233ms  |
| 8   | 960 / 0   | **7988**    | **104ms**| 125ms    | 5374ms  |

## 关键结论

1. **全部 0 失败**：4 个 treatment × 4 个 QPS 阶段，共 3840 个请求全部成功
2. **TTFT 随 QPS 增加不退化（反而变好）**：qlen256-olen256 从 1 QPS 79ms → 8 QPS 66ms，这是 precise-prefix-routing 的核心价值体现：相同 prefix 的请求路由到同一 pod，KV cache 命中后省掉 prefill 计算，TTFT 随并发增加而降低
3. **吞吐随 QPS 线性扩展**：olen1024 场景 8 QPS 达到 7988 tok/s，接近 8000 tok/s 上限
4. **与随机负载对比（TTFT p50，8 QPS）**：
   - 共享前缀 qlen256：66ms vs 随机 75ms → **提升 12%**
   - 共享前缀 qlen1024：96ms vs 随机 101ms → **提升 5%**

## 运行环境备注

首次运行（2026-07-17 01:xx）因 h200-12-3 根盘 DiskPressure（90% 占用）导致 pod 驱逐，测试中断。  
修复：将 `/var/lib/containerd` 迁移到 `/home/data`（7TB），根盘从 90% 降至 51%，第二次运行全部成功。

## 复现命令

```bash
cd /root/ai-model-gateway-base/gateway-benchmark
bash run_llmd.sh --workload sweep_shared_prefix.yaml --experiment throughput_sweep.yaml
```
