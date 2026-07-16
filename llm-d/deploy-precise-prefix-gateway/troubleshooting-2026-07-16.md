# 固安 llm-d 路由网关部署问题记录

## 2026-07-16

---

## 问题一：agentgateway pod 持续 CrashLoopBackOff

### 现象
agentgateway controller 无法启动，日志：
```
Error: err in main: Get "https://10.96.0.1:443/api/v1/namespaces/agentgateway-system/secrets/kgateway-xds-cert": dial tcp 10.96.0.1:443: i/o timeout
```

### 根因
calico BPF 模式切换到 iptables 模式后，felix 配置中残留了 BPF 相关设置，导致 pod 内 NAT 行为异常，无法访问 ClusterIP：
- `bpfConnectTimeLoadBalancing: TCP`
- `bpfHostNetworkedNATWithoutCTLB: Enabled`

注：calico bird 会给每个节点自己的 pod CIDR 写一条 blackhole 路由（如 `blackhole 172.31.112.128/26 proto bird`），这是 IPIP 模式的正常行为，不是问题所在。

### 修复
```bash
kubectl patch felixconfiguration default --type=merge -p '{
  "spec": {
    "bpfConnectTimeLoadBalancing": "Disabled",
    "bpfHostNetworkedNATWithoutCTLB": "Disabled"
  }
}'

# 重建 pod 使配置生效
kubectl delete pod -n agentgateway-system -l app.kubernetes.io/name=agentgateway
```

---

## 问题二：agentgateway pod 调度到 GPU 节点

### 现象
删除 crashloop pod 后，新 pod 被调度到 h200-12-3，拉取镜像失败（网络不通），且占用 GPU 节点资源。

### 根因
agentgateway deployment 没有 nodeSelector，默认随机调度。

### 修复
固定在 master01 上运行：
```bash
kubectl patch deployment agentgateway -n agentgateway-system --type=json -p='[
  {"op":"add","path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/hostname":"master01"}},
  {"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}
]'
```

同时在 master01 和 h200-12-3 补打缺失的镜像 tag（kubelet 会尝试拉取 `cr.agentgateway.dev/` 前缀的镜像）：
```bash
# 在各节点上执行
ctr -n k8s.io image tag ghcr.io/agentgateway/controller:v1.3.1 cr.agentgateway.dev/controller:v1.3.1
ctr -n k8s.io image tag ghcr.io/agentgateway/agentgateway:v1.3.1 cr.agentgateway.dev/agentgateway:v1.3.1
```

---

## 问题三：vLLM pod Pending — GPU 资源未上报

### 现象
vLLM model pod 一直 Pending：
```
0/2 nodes are available: 2 Insufficient nvidia.com/gpu
```
nvidia device plugin 日志：
```
E factory.go:112] Incompatible strategy detected auto
I main.go:381] No devices found. Waiting indefinitely.
```
`kubectl get node h200-12-3` 的 Capacity/Allocatable 中无 `nvidia.com/gpu` 字段。

### 根因
h200-12-3 上 `nvidia-container-runtime` 二进制已安装，但 containerd 未配置使用它，device plugin 无法发现 GPU。

### 修复（在 h200-12-3 上执行）
```bash
# 自动注入 nvidia runtime 到 containerd 配置
nvidia-ctk runtime configure --runtime=containerd
# 配置写入 /etc/containerd/conf.d/99-nvidia.toml

# 重启 containerd
systemctl restart containerd

# 重启 device plugin
kubectl rollout restart daemonset nvidia-device-plugin-daemonset -n kube-system

# 验证
kubectl get node h200-12-3 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

---

## 问题四：模型文件传输大小异常（22G vs 15G）

### 现象
使用 `rsync -aL` 从源端同步后，目标目录变成 22G，而源端只有 15G。

### 根因
HuggingFace Hub 缓存结构：`snapshots/` 下的文件是指向 `blobs/` 的软链。
`-aL` 参数跟随软链将实际文件内容复制，导致 `blobs/`（15G）和 `snapshots/`（展开后约 7G）都被完整复制，共 22G。

### 修复
只需 `snapshots/` 中的实际内容，不需要保留 hub 缓存结构：
```bash
# 删除冗余 blobs 目录
rm -rf /home/data/models/hub/models--Qwen--Qwen2.5-7B-Instruct/blobs

# 后续同步使用 -a（不带 -L），文件已是实际内容不再有需要跟随的软链
rsync -a --progress src/ dst/
```

---

## 备注

- 集群：master01（116.198.67.18）+ h200-12-3（11.194.12.3，NVIDIA H200 144G）
- 模型：Qwen2.5-7B-Instruct，存放于 h200-12-3 的 `/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct`
- 部署脚本目录：`/root/ai-model-gateway-base/llm-d/deploy-precise-prefix-gateway/`

---

## 问题六：H200 CUDA Error 802 — NVSwitch Fabric 未初始化

### 现象
容器内 `torch.cuda.is_available()` 返回 `False`，`cuInit(0)` 返回 802：
```
CUDA initialization: Unexpected error from cudaGetDeviceCount(). Error 802: system not yet initialized
```
宿主机上 `nvidia-smi` 正常，但 `cuInit` 同样返回 802。

### 根因
H200 是 NVSwitch 多 GPU 架构，必须运行 `nvidia-fabricmanager` 服务才能完成 GPU Fabric 初始化。
Fabric 未就绪时 `nvidia-smi -q` 显示 `Fabric: State: In Progress`，CUDA 驱动拒绝初始化。

### 修复命令
```bash
# 从 NVIDIA 官方 CUDA repo 下载与驱动版本精确匹配的 fabricmanager
# 注意：ubuntu 22.04 和 24.04 包名不同，包名是 nvidia-fabricmanager（不带版本后缀）
curl -fsSL \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvidia-fabricmanager_580.126.20-1_amd64.deb \
  -o /tmp/nvidia-fabricmanager_580.126.20.deb

dpkg -i /tmp/nvidia-fabricmanager_580.126.20.deb
systemctl enable nvidia-fabricmanager
systemctl start nvidia-fabricmanager

# 验证 Fabric 就绪
nvidia-smi -q | grep -A3 Fabric | grep State
# 预期: State: Completed

# 验证 CUDA 可用
python3 -c "import ctypes; lib=ctypes.CDLL('libcuda.so.1'); print('cuInit:', lib.cuInit(0))"
# 预期: cuInit: 0
```

> 注意：fabricmanager 版本必须与驱动版本精确匹配（如驱动 580.126.20 → fabricmanager 580.126.20）。
> 可在 https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/Packages.gz 中搜索对应版本。
> fabricmanager 需要设置为开机自启，否则重启后 CUDA 再次无法初始化。
