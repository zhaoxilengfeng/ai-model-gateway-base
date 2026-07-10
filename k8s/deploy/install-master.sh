#!/bin/bash
# install-master.sh — 在 master 节点上初始化 K8s v1.35 控制平面
#
# 前置：所有节点已运行 prepare.sh
#
# Usage: bash install-master.sh
#
# 环境变量（可覆盖）：
#   MASTER_IP       master 节点内网 IP（必填）
#   POD_CIDR        Pod 网段，默认 10.244.0.0/16（flannel 默认）
#   SERVICE_CIDR    Service 网段，默认 10.96.0.0/12
#   K8S_VERSION     K8s 版本，默认 1.35.0
set -e

MASTER_IP="${MASTER_IP:?请设置 MASTER_IP，例如：MASTER_IP=10.0.0.3 bash install-master.sh}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
K8S_VERSION="${K8S_VERSION:-1.35.0}"

echo "=== 1. kubeadm init ==="
kubeadm init \
  --apiserver-advertise-address="$MASTER_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --service-cidr="$SERVICE_CIDR" \
  --kubernetes-version="v${K8S_VERSION}" \
  --image-repository=registry.cn-hangzhou.aliyuncs.com/airouter \
  --cri-socket=unix:///run/containerd/containerd.sock \
  | tee /tmp/kubeadm-init.log

echo "=== 2. 配置 kubectl ==="
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "=== 3. 安装 Calico 网络插件 ==="
CALICO_YAML="/root/deploy/k8s/calico.yaml"
if [ ! -f "$CALICO_YAML" ]; then
  echo "ERROR: $CALICO_YAML 不存在，请先运行 prepare.sh" >&2
  exit 1
fi
kubectl apply -f "$CALICO_YAML"

echo "=== 4. 等待控制平面就绪 ==="
kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s

echo ""
echo "=== 控制平面状态 ==="
kubectl get nodes
kubectl get pods -n kube-system

echo ""
echo "=== Worker 节点加入命令 ==="
echo "在每台 worker 节点上执行："
kubeadm token create --print-join-command
