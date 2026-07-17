# TPM 测量：Qwen Coder Trace 真实编码场景

**日期**: 2026-07-17  
**网关**: llmd  
**结果目录**: `results/llmd/inference-perf/tpm_coder_20260717_082222`  

## 总体概览

| 指标 | 数值 |
|------|------|
| 总请求数 | 1,901 |
| 成功 / 失败 | 1,901 / 0 (100.0%) |
| 输出吞吐 | 2,773 tokens/s |
| TTFT p50 | 155ms |
| TTFT p99 | 1689ms |
| E2E p50 | 3.219s |

## 各阶段详情

| 阶段 | 成功/失败 | output tok/s | TTFT p50 | TTFT p90 | TTFT p99 | TPOT p50 | E2E p50 |
|------|-----------|-------------|---------|---------|---------|---------|---------|
| 2 QPS | 405/0 | 1,504 | 125ms | 278ms | 641ms | 4.9ms | 2.797s |
| 3 QPS | 355/0 | 2,520 | 135ms | 306ms | 590ms | 5.0ms | 3.026s |
| 5 QPS | 384/0 | 3,855 | 151ms | 479ms | 908ms | 5.2ms | 2.916s |
| 6 QPS | 399/0 | 4,027 | 169ms | 991ms | 1534ms | 5.5ms | 3.419s |
| 6 QPS | 358/0 | 4,871 | 368ms | 1546ms | 2211ms | 5.8ms | 4.299s |

## Token 分布

| 指标 | 均值 | p50 | p90 |
|------|------|-----|-----|
| Input token | 2848 | 2388 | 6037 |
| Output token | 752 | 546 | 1570 |

**KV cache 命中率**: 0.0%  

## 复现命令

```bash
cd /root/ai-model-gateway-base/gateway-benchmark
bash run_llmd.sh --workload tpm_coder_profile.yaml
```
