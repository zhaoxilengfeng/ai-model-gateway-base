# llm-d Gateway 模式部署（Agentgateway）

基于官方 [optimized-baseline gateway mode](https://github.com/llm-d/llm-d/tree/v0.8.1/guides/optimized-baseline)，使用 `llm-d-router-gateway` chart + Agentgateway。

## 架构

```
Client → Agentgateway (NodePort) → HTTPRoute → InferencePool → EPP → vLLM pods
```

Router Gateway 模式将 EPP 和 Proxy 分离，Proxy 由外部 Gateway controller（Agentgateway）管理，支持水平扩展。

## 组件版本

| 组件 | 版本 |
|---|---|
| llm-d-router-gateway chart | v0.9.0 |
| llm-d-router-endpoint-picker (EPP) | v0.9.0 |
| agentgateway | v1.1.0 |
| vllm/vllm-openai | v0.8.5 |
| GIE CRDs | v1.5.0 |

## 部署流程

```bash
# 1. 下载依赖
bash prepare.sh

# 2. 拉取镜像
bash downlowd-image.sh

# 3. 安装（含 Agentgateway + llm-d router）
bash install.sh

# 4. 部署模型
bash deploy-model.sh
```

## 访问方式

```bash
# Agentgateway NodePort（集群外）
NODE_PORT=$(kubectl get svc -n agentgateway-system \
  -l "gateway.networking.k8s.io/gateway-name=llm-d-gateway" \
  -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}')
curl http://<node-ip>:${NODE_PORT}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```
