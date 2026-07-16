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


---

## 常见问题排查

### agentgateway controller 启动报 `dial tcp 10.96.0.1:443: i/o timeout`

**现象**：agentgateway pod 持续 CrashLoopBackOff，日志：

```
Error: err in main: Get "https://10.96.0.1:443/api/v1/namespaces/agentgateway-system/secrets/kgateway-xds-cert": dial tcp 10.96.0.1:443: i/o timeout
```

**根因**：calico bird 将本机 pod CIDR 写成了 blackhole 路由，导致本机 pod 无法访问 ClusterIP（10.96.0.1）。

**排查命令**：

```bash
# 查看是否存在 blackhole 路由
ip route | grep blackhole
# 预期看到类似：blackhole 172.31.112.128/26 proto bird
```

**修复命令**：

```bash
# 删除 blackhole 路由（将网段替换为实际值）
ip route del blackhole 172.31.112.128/26

# 验证删除
ip route | grep blackhole

# 强制重建 agentgateway pod
kubectl delete pod -n agentgateway-system -l app.kubernetes.io/name=agentgateway
```

> 注意：此 blackhole 路由在节点重启或 calico bird 重新收敛后可能复现。若频繁出现，需排查 calico IPAM block 分配与节点路由通告是否冲突。

---

### agentgateway 必须调度到 control-plane 节点（不得调度到 GPU 节点）

agentgateway-system 的 pod 应固定在 master01，不要占用 GPU worker 节点资源。

**一次性 patch 命令**：

```bash
kubectl patch deployment agentgateway -n agentgateway-system --type=json -p='[
  {"op":"add","path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/hostname":"master01"}},
  {"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}
]'
```

**验证**：

```bash
kubectl get pod -n agentgateway-system -o wide
# NODE 列应为 master01
```


### nvidia device plugin 无法发现 GPU（node 缺少 nvidia.com/gpu 资源）

**现象**：vLLM pod 一直 Pending，`kubectl describe pod` 显示：
```
0/2 nodes are available: 2 Insufficient nvidia.com/gpu
```
`kubectl get node h200-xx -o yaml | grep gpu` 输出空，Capacity/Allocatable 里无 `nvidia.com/gpu`。

nvidia device plugin 日志：
```
E factory.go:112] Incompatible strategy detected auto
E factory.go:113] If this is a GPU node, did you configure the NVIDIA Container Toolkit?
I main.go:381] No devices found. Waiting indefinitely.
```

**根因**：`nvidia-container-runtime` 二进制已安装，但 containerd 未配置使用它，device plugin 无法通过 containerd 发现 GPU。

**修复命令**（在 GPU 节点上执行）：
```bash
# 自动注入 nvidia runtime 到 containerd 配置
nvidia-ctk runtime configure --runtime=containerd

# 重启 containerd 使配置生效
systemctl restart containerd

# 重启 device plugin 重新发现 GPU
kubectl rollout restart daemonset nvidia-device-plugin-daemonset -n kube-system

# 验证 GPU 资源已上报
kubectl get node <gpu-node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
# 预期输出: 1 (或更多)
```

**验证**：
```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```

---

### calico BPF 模式切换到 iptables 后 pod 无法访问 ClusterIP

**现象**：pod 内访问 `https://10.96.0.1:443` 超时，日志：
```
dial tcp 10.96.0.1:443: i/o timeout
```

**根因**：calico 从 BPF 模式切换到 iptables 模式后，felix 配置中残留了：
- `bpfConnectTimeLoadBalancing: TCP`
- `bpfHostNetworkedNATWithoutCTLB: Enabled`

这两个 BPF 配置在 iptables 模式下干扰 NAT 行为，导致 pod 内连接无法正确建立。

**修复命令**：
```bash
kubectl patch felixconfiguration default --type=merge -p '{
  "spec": {
    "bpfConnectTimeLoadBalancing": "Disabled",
    "bpfHostNetworkedNATWithoutCTLB": "Disabled"
  }
}'
```

**验证**：
```bash
kubectl get felixconfiguration default -o yaml | grep bpf
```
