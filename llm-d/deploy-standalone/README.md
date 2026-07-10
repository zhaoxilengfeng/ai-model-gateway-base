# llm-d Standalone 模式部署

基于官方 [optimized-baseline](https://github.com/llm-d/llm-d/tree/v0.8.1/guides/optimized-baseline) 指南，使用 `llm-d-router-standalone` chart。

## 架构

```
Client → EPP Service (ClusterIP) → Envoy sidecar → vLLM pods
```

Router Standalone 模式内置 Envoy proxy（作为 EPP pod 的 sidecar），不依赖外部 Gateway controller。

## 组件版本

| 组件 | 版本 |
|---|---|
| llm-d-router-standalone chart | v0.9.0 |
| llm-d-router-endpoint-picker (EPP) | v0.9.0 |
| envoyproxy/envoy | distroless-v1.33.2 |
| vllm/vllm-openai | v0.8.5（driver 570 对应 CUDA 12.8，不支持 v0.23.0） |
| GIE CRDs | v1.5.0 |

## 部署流程

```bash
# 1. 下载依赖（chart + GIE manifests）
bash prepare.sh

# 2. 拉取镜像到本地 containerd
bash downlowd-image.sh

# 3. 安装
bash install.sh

# 4. 部署模型
bash deploy-model.sh
```

## 访问方式

```bash
# EPP Service ClusterIP（集群内）
export IP=$(kubectl get svc quickstart-epp -n llm-d-standalone -o jsonpath='{.spec.clusterIP}')
curl http://${IP}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```
