#!/bin/bash
# join-worker.sh — 将 worker 节点加入 K8s 集群
#
# 前置：master 已运行 install-master.sh
#
# Usage: bash join-worker.sh <kubeadm-join-command>
# 示例: bash join-worker.sh "kubeadm join 10.0.0.3:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyy"
#
# 或直接传入完整 join 参数：
#   JOIN_CMD="kubeadm join ..." bash join-worker.sh
#
# 环境变量（可覆盖）：
#   K8S_VERSION   K8s 版本，默认 1.35.0
set -e

K8S_VERSION="${K8S_VERSION:-1.35.0}"
JOIN_CMD="${JOIN_CMD:-$*}"

if [ -z "$JOIN_CMD" ]; then
  echo "Usage: bash $0 <kubeadm-join-command>" >&2
  echo "  在 master 节点执行 'kubeadm token create --print-join-command' 获取" >&2
  exit 1
fi

echo "=== 0. 系统基础配置 ==="
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "=== 1. Install/upgrade containerd ==="
# 卸载旧版 containerd.io（Docker 安装的旧版不支持 CRI v1 API）
apt-get remove -y -qq containerd.io 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# sandbox image 使用阿里云缓存（registry.k8s.io 国内不通）
# containerd v2 字段名为 sandbox
sed -i "s|sandbox = 'registry.k8s.io/pause:.*'|sandbox = 'registry.cn-hangzhou.aliyuncs.com/airouter/pause:3.10.1'|" \
  /etc/containerd/config.toml

systemctl restart containerd
sleep 2
systemctl is-active containerd

echo "=== 2. Install kubeadm / kubelet / kubectl (v${K8S_VERSION}) ==="
apt-get install -y -qq apt-transport-https ca-certificates curl gpg

K8S_MINOR=$(echo "$K8S_VERSION" | cut -d. -f1-2)
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt-get install -y -qq \
  kubelet="${K8S_VERSION}-1.1" \
  kubeadm="${K8S_VERSION}-1.1" \
  kubectl="${K8S_VERSION}-1.1"
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet

echo "=== 3. 清理旧集群残留 ==="
kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock 2>/dev/null || true
rm -rf /etc/cni/net.d /root/.kube

echo "=== 4. 加入集群 ==="
eval "$JOIN_CMD" --cri-socket=unix:///run/containerd/containerd.sock

echo ""
echo "Done. 在 master 节点验证："
echo "  kubectl get nodes"
