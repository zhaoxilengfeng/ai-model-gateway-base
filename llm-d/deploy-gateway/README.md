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
| agentgateway | v1.3.1 |
| vllm/vllm-openai | v0.23.0（需要 NVIDIA 驱动 ≥ 580，CUDA 13.0） |
| GIE CRDs | v1.5.0 |

## 变更记录

| 时间 | 变更 |
|------|------|
| 2026-07-10 | agentgateway v1.1.0 → v1.3.1（v1.1.0 阿里云有缓存，v1.3.1 需手动导入 tar） |
| 2026-07-10 | vllm-openai v0.8.5 → v0.23.0（宿主机驱动需升级至 580） |

## 部署流程

```bash
# 1. 下载依赖
bash prepare.sh

# 2. 拉取镜像（agentgateway 镜像需手动导入，见注意事项）
bash downlowd-image.sh

# 3. 安装（含 Agentgateway + llm-d router）
bash install.sh

# 4. 部署模型
bash deploy-model.sh
```

## 注意事项

### GPU 驱动要求

同 standalone 模式，vLLM v0.23.0 需要宿主机 **NVIDIA 驱动 ≥ 580（CUDA 13.0）**。详见 [deploy-standalone/README.md](../deploy-standalone/README.md)。

### agentgateway 镜像

`cr.agentgateway.dev` 和 `ghcr.io` 在当前环境无法通过代理直接拉取（skopeo 不支持 socks5），需手动导入：

```bash
# 在控制节点导入
ctr -n k8s.io image import controller-v1.3.1.tar
ctr -n k8s.io image import agentgateway-v1.3.1.tar

# 推送到各 worker 节点
for node_ip in 10.0.0.2 10.0.0.4 10.0.0.5; do
  cat controller-v1.3.1.tar  | ssh root@${node_ip} "ctr -n k8s.io image import -"
  cat agentgateway-v1.3.1.tar | ssh root@${node_ip} "ctr -n k8s.io image import -"
done
```

## 访问方式

```bash
# NodePort（install.sh 完成后会打印地址）
NODE_PORT=$(kubectl get svc llm-d-inference-gateway -n llm-d-gateway \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
NODE_IP=<任意 worker 节点 IP>
curl http://${NODE_IP}:${NODE_PORT}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```

请求路径：NodePort → agentgateway pod → HTTPRoute → InferencePool → EPP → vLLM pod
