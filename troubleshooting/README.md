# 问题排查记录

本目录记录部署和运维过程中遇到的问题、排查过程及解决方案。

## 索引

| 文件 | 问题概述 | 涉及组件 |
|---|---|---|
| [precise-prefix-zmq-not-working.md](precise-prefix-zmq-not-working.md) | 精准前缀路由 EPP ZMQ 索引未建立，prefix-cache-scorer 持续 score 0 | precise-prefix-cache-routing EPP / vLLM |
| [vllm-cuda-error-804.md](vllm-cuda-error-804.md) | vLLM pod CrashLoopBackOff，CUDA Error 804 forward compatibility | vLLM / NVIDIA Driver |
| [render-service-tokenizer-download.md](render-service-tokenizer-download.md) | render service 启动失败，联网下载 tokenizer 超时 | precise-prefix render service |
| [agentgateway-crd-missing.md](agentgateway-crd-missing.md) | agentgateway pod CrashLoopBackOff，CRD not found | agentgateway v1.3.1 |
