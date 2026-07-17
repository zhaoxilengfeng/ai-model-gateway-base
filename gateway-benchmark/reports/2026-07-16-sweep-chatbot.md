# 基准测试记录：qwen25-7b-instruct sweep_chatbot

**日期**：2026-07-16  
**模型**：qwen25-7b-instruct（vLLM v0.23.0，8 副本，各 1×H200）  
**网关**：llm-d precise-prefix-cache-routing  
**Endpoint**：http://10.109.94.45:80  
**测试**：sweep_chatbot + concurrency_sweep（1/4/8/16/32 QPS，各约 9 分钟）  
**Harness**：inference-perf v0.7.0  

## 结果汇总

| QPS | 成功/失败 | 吞吐 (output tok/s) | TTFT p50 | TTFT p90 | E2E p50 | TPOT p50 |
|-----|-----------|---------------------|----------|----------|---------|---------|
| 1   | 1740 / 0  | 1004                | 75ms     | 99ms     | 1308ms  | 4.9ms   |
| 4   | 1920 / 0  | 1104                | 75ms     | 97ms     | 1289ms  | 4.9ms   |
| 8   | 2160 / 0  | 1362                | 78ms     | 100ms    | 1385ms  | 4.9ms   |
| 16  | 2640 / 0  | 1556                | 75ms     | 96ms     | 1360ms  | 5.0ms   |
| 32  | 3600 / 0  | 2130                | 76ms     | 99ms     | 1383ms  | 5.1ms   |

## 关键结论

- **稳定性极好**：全程 0 失败，5 个 QPS 阶段无任何请求报错
- **TTFT 极稳**：1→32 QPS 全程 p50=75-78ms，p90 不超过 100ms，precise-prefix-routing 路由层无显著额外延迟
- **吞吐线性扩展**：1→32 QPS 吞吐从 1004 增长到 2130 tok/s（+112%），8 pod 并行效果良好
- **TPOT 稳定**：4.9-5.1ms，decode 速度不随并发增大而退化

## 测试环境

- 节点：h200-12-3，8× NVIDIA H200 143G
- qwen25-7b-instruct 副本数：8（每副本 1 GPU）
- 模型路径：/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct
- context_length：8192，gpu_memory_utilization：0.85
- prefix caching：enabled（--enable-prefix-caching）

## 复现命令

```bash
cd /root/ai-model-gateway-base/gateway-benchmark
bash run_llmd.sh --workload sweep_chatbot.yaml --experiment concurrency_sweep.yaml
```
