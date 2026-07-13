# llm-d 精准前缀哈希路由（Gateway 模式 + Agentgateway）

基于 [precise-prefix-cache-routing](https://github.com/llm-d/llm-d/tree/v0.8.1/guides/precise-prefix-cache-routing) 指南，在精准前缀路由基础上采用 **Gateway 模式**，以 agentgateway 作为数据面 proxy 对外暴露服务。

---

## 与 deploy-precise-prefix（Standalone 模式）的区别

| 特性 | Standalone（deploy-precise-prefix）| Gateway（本目录）|
|---|---|---|
| 入口 | EPP ClusterIP（集群内）| agentgateway NodePort（集群外可访问）|
| 数据面 | EPP 内置 Envoy sidecar | agentgateway proxy（独立 Deployment）|
| Helm chart | llm-d-router-standalone | llm-d-router-gateway |
| 资源 | EPP + InferencePool | EPP + InferencePool + Gateway + HTTPRoute |
| 路由核心 | 精准 ZMQ KV 块哈希 | 精准 ZMQ KV 块哈希（相同）|

精准前缀路由的核心机制（ZMQ、block-size=64、token-producer）完全一致，只是流量入口从 EPP ClusterIP 改为 agentgateway NodePort。

---

## 架构

```
Client
  │
  ▼
NodePort（agentgateway proxy）
  │  agentgateway controller 通过 xDS 下发路由配置
  ▼
HTTPRoute / llm-d-inference-gateway
  │  path: / → InferencePool
  ▼
InferencePool（precise-prefix-cache-routing）
  │  endpointPickerRef → EPP :9002
  ▼
EPP（精准前缀路由）
  │  ZMQ SUB → 每个 vLLM pod :5556（KV 块事件）
  │  token-producer → render service :8000（tokenize）
  ▼
vLLM pod（--block-size=64，--kv-events-config ZMQ）
```

---

## 部署流程

```bash
# 1. 下载依赖
bash prepare.sh

# 2. 拉取镜像
bash downlowd-image.sh

# 3. 安装（agentgateway + render service + EPP + Gateway + HTTPRoute）
bash install.sh

# 4. 部署模型（含 ZMQ kv-events 配置）
bash deploy-model.sh
```

---

## 注意事项

### agentgateway 镜像

`cr.agentgateway.dev` 在当前环境无法通过代理直接拉取，需手动导入 tar：

```bash
for node_ip in 10.0.0.2 10.0.0.4 10.0.0.5; do
  cat controller-v1.3.1.tar  | ssh root@${node_ip} "ctr -n k8s.io image import -"
  cat agentgateway-v1.3.1.tar | ssh root@${node_ip} "ctr -n k8s.io image import -"
done
```

### EPP 与 vLLM pod 的启动顺序

`deploy-model.sh` 在模型部署完成后会自动重启 EPP，确保 pod-discovery 正确建立 ZMQ 订阅。

若后续 `kubectl rollout restart` vLLM 后精准路由失效，需手动重启 EPP：

```bash
kubectl rollout restart deployment/precise-prefix-cache-routing-epp -n llm-d-precise-prefix-gw
```

### block-size 与 token-producer modelName 必须一致

- vLLM `--block-size=64` 须与 EPP `tokenProcessorConfig.blockSize=64` 一致
- render `--served-model-name` 须与 EPP `token-producer.modelName` 以及 vLLM `--served-model-name` 三处一致

详见 [troubleshooting](../../troubleshooting/precise-prefix-zmq-not-working.md)。

---

## 访问方式

```bash
NODE_PORT=$(kubectl get svc llm-d-inference-gateway -n llm-d-precise-prefix-gw \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
NODE_IP=<任意 worker 节点 IP>

curl http://${NODE_IP}:${NODE_PORT}/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen25-7b-instruct","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```

请求路径：NodePort → agentgateway proxy → HTTPRoute → InferencePool → EPP（精准前缀选路）→ vLLM pod
