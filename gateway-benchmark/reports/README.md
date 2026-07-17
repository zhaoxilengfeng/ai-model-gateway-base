# 基准测试报告汇总

每次完整测试后运行 `bash report.sh` 自动生成报告到本目录。

## 生成报告

```bash
cd /root/ai-model-gateway-base/gateway-benchmark

# 对最新一次测试生成报告
bash report.sh

# 指定结果目录
bash report.sh results/llmd/inference-perf/20260717_055659 \
  --name "2026-07-17-qwen-coder-trace" \
  --title "Qwen Coder Trace 编码场景"

# 对比报告：手工整合两次测试（compare.sh 输出重定向）
bash compare.sh results/A results/B A标签 B标签 > /tmp/compare.txt
```

## 报告列表

| 日期 | 场景 | 关键结论 |
|------|------|---------|
| [2026-07-16](2026-07-16-sweep-chatbot.md) | sweep_chatbot 随机负载（1/4/8/16/32 QPS） | TTFT p50 全程 75-78ms，32 QPS 吞吐 2130 tok/s，0 失败 |
| [2026-07-17](2026-07-17-sweep-shared-prefix.md) | sweep_shared_prefix 共享前缀（1/2/4/8 QPS） | TTFT 随并发增加反而降低（KV cache 命中），最高 7988 tok/s |
| [2026-07-17](2026-07-17-tpm-random.md) | TPM 测量：随机输入 | 饱和点 400c，output TPM ~150万，TTFT p99=988ms |
| [2026-07-17](2026-07-17-tpm-comparison.md) | TPM 对比：随机 vs 共享前缀 | 共享前缀 output TPM 比随机高 40%（150万→210万） |
| [2026-07-17](2026-07-17-qwen-coder-trace.md) | Qwen Coder Trace 真实编码场景 | TTFT p50=125ms，E2E p50=2.76s，Input 均值 2379 token |

## 命名规范

文件名格式：`YYYY-MM-DD-<场景简称>.md`

- `sweep-chatbot` — 随机负载阶梯压测
- `sweep-shared-prefix` — 共享前缀场景
- `tpm-random` — 随机输入 TPM 上限
- `tpm-shared-prefix` — 共享前缀 TPM 上限
- `tpm-comparison` — TPM 对比报告
- `qwen-coder-trace` — 真实编码场景
- `vs-random-routing` — 精准前缀 vs 随机路由对比
