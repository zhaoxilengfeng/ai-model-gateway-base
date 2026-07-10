#!/bin/bash
# uninstall.sh — 清理 K8s 集群（在每台节点上执行）
#
# Usage:
#   master 节点：bash uninstall.sh
#   worker 节点：bash uninstall.sh
set -e

echo "=== 1. kubeadm reset ==="
kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock

echo "=== 2. 清理网络配置 ==="
rm -rf /etc/cni/net.d
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
# Calico 网络接口
ip link delete tunl0 2>/dev/null || true
for iface in $(ip link show | grep -oP 'cali\w+'); do
  ip link delete "$iface" 2>/dev/null || true
done

echo "=== 3. 清理 kubectl 配置 ==="
rm -rf "$HOME/.kube"

echo ""
echo "Done. 节点已重置，可重新运行 install-master.sh 或 join-worker.sh。"
