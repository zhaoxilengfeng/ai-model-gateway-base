# TPM 上限测量结果

**日期**：2026-07-17  
**模型**：qwen25-7b-instruct（vLLM v0.23.0，8 副本，各 1×H200）  
**网关**：llm-d precise-prefix-cache-routing  
**场景**：随机输入（均值 512 token），随机输出（均值 256 token）  
**方法**：concurrent 模式，逐步提升并发数找饱和点 + TTFT p99 SLO 约束  

## 完整数据（合并两次测试）

| 并发数 | 成功/失败 | output tok/s | output TPM | total TPM | TTFT p50 | TTFT p99 | 状态 |
|--------|-----------|-------------|-----------|----------|---------|---------|------|
| 32c    | 400/0     | 5,521       | 331,234   | 935,606  | 77ms    | 176ms   | 正常 |
| 64c    | 400/0     | 9,820       | 589,227   | 1,663,140| 81ms    | 183ms   | 正常 |
| 128c   | 400/0     | 16,092      | 965,515   | 2,714,492| 111ms   | 360ms   | 正常 |
| 200c   | 400/0     | 20,104      | 1,206,262 | 3,390,544| 140ms   | 572ms   | 正常 |
| 300c   | 400/0     | 24,242      | 1,454,513 | 4,097,725| 174ms   | 844ms   | 正常 |
| **400c** | 400/0   | **24,989**  | **1,499,362** | **4,221,379** | 200ms | **988ms** | **饱和 ←** |
| 500c   | 399/1     | 23,144      | 1,388,632 | 3,995,290| 207ms   | 1117ms  | 过载 |

## 结论

**TTFT p99 ≤ 1000ms SLO 约束下：**

| 指标 | 数值 |
|------|------|
| 有效峰值 output TPM | **1,499,362**（约 150 万） |
| 有效峰值 total TPM（input+output）| **4,221,379**（约 420 万） |
| 饱和并发数 | 400 |
| 饱和点 TTFT p50/p99 | 200ms / 988ms |

## 关键观察

1. **线性增长区**（32c → 300c）：output TPM 从 33 万线性增长到 145 万，TTFT p99 从 176ms 增至 844ms
2. **饱和点**（400c）：output TPM 达到峰值 150 万，TTFT p99 = 988ms，恰好在 SLO 边界
3. **过载点**（500c）：吞吐反而下降至 139 万，出现失败请求，TTFT p99 超 SLO
4. **结合 vLLM metrics** 可见 GPU 在 400c 时 utilization ≈ 100%

## 测量方法说明

- **工具**：llmdbenchmark concurrent 模式，等价于 vLLM `--request-rate inf`
- **TPM 定义**：output TPM = output tok/s × 60；total TPM = (input+output) tok/s × 60
- **有效 TPM** = TTFT p99 ≤ SLO 约束下的最高 output TPM（生产建议使用 total TPM）

## 复现命令

```bash
cd /root/ai-model-gateway-base/gateway-benchmark

# 快速验证（找饱和区间）
bash measure-tpm.sh --concurrency 32,64,128,200 --requests 400

# 精确定位（在已知区间内细化）
bash measure-tpm.sh --concurrency 200,300,400,500 --requests 400

# 自定义 SLO（如要求 p99 ≤ 500ms）
bash measure-tpm.sh --concurrency 32,64,128,200,300,400 --requests 400 --slo 500
```
