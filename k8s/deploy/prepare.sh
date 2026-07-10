#!/bin/bash
# prepare.sh — 在所有节点上安装 K8s v1.35 依赖（kubeadm / kubelet / kubectl + containerd）
#
# 在每台节点上单独执行，master 和 worker 均需运行。
#
# Usage: bash prepare.sh
#
# 环境变量（可覆盖）：
#   K8S_VERSION   K8s 版本，默认 1.35.0
set -e

K8S_VERSION="${K8S_VERSION:-1.35.0}"

echo "=== 0. 系统基础配置 ==="

# 关闭 swap（K8s 要求）
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

# 加载内核模块
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 内核参数
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "=== 1. Install containerd ==="
# 卸载旧版 containerd.io（Docker 安装的旧版不支持 CRI v1 API，K8s 1.35 要求 containerd v2+）
apt-get remove -y -qq containerd.io 2>/dev/null || true
apt-get autoremove -y -qq 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq containerd

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
# systemd cgroup driver（K8s 1.22+ 推荐）
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# sandbox image 使用阿里云缓存（registry.k8s.io 国内不通）
# containerd v2 字段名为 sandbox，不是 sandbox_image
sed -i "s|sandbox = 'registry.k8s.io/pause:.*'|sandbox = 'registry.cn-hangzhou.aliyuncs.com/airouter/pause:3.10.1'|" \
  /etc/containerd/config.toml
# 配置阿里云仓库认证（供 kubeadm init 拉取控制平面镜像）
ALIYUN_AUTH=$(cat ~/.docker/config.json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('auths',{}).get('registry.cn-hangzhou.aliyuncs.com',{}).get('auth',''))
" 2>/dev/null || echo "")
if [ -n "$ALIYUN_AUTH" ]; then
  ALIYUN_USER=$(echo "$ALIYUN_AUTH" | base64 -d | cut -d: -f1)
  ALIYUN_PASS=$(echo "$ALIYUN_AUTH" | base64 -d | cut -d: -f2-)
  python3 - "$ALIYUN_USER" "$ALIYUN_PASS" <<'PYEOF'
import sys
user, passwd = sys.argv[1], sys.argv[2]
path = '/etc/containerd/config.toml'
content = open(path).read()
auth_line = f'      [plugins.\'io.containerd.grpc.v1.cri\'.registry.configs."registry.cn-hangzhou.aliyuncs.com".auth]\n        username = "{user}"\n        password = "{passwd}"\n'
if 'registry.cn-hangzhou.aliyuncs.com' not in content:
    content = content.replace(
        "[plugins.'io.containerd.grpc.v1.cri'.registry]",
        "[plugins.'io.containerd.grpc.v1.cri'.registry]\n" + auth_line
    )
    open(path, 'w').write(content)
    print('  aliyun auth config added')
PYEOF
fi

systemctl enable --now containerd
systemctl restart containerd

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
apt-get install -y -qq \
  kubelet="${K8S_VERSION}-1.1" \
  kubeadm="${K8S_VERSION}-1.1" \
  kubectl="${K8S_VERSION}-1.1"
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet

# ── 3. Calico manifest（仅 master 节点需要，worker 跳过）────────────────────────
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
CALICO_YAML="/root/deploy/k8s/calico.yaml"
mkdir -p /root/deploy/k8s
echo "=== 3. Download Calico manifest (${CALICO_VERSION}) ==="
if [ -f "$CALICO_YAML" ]; then
  echo "  已存在，跳过（如需重新下载请删除 $CALICO_YAML）"
else
  https_proxy=socks5h://127.0.0.1:1080 curl -sL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    -o "$CALICO_YAML"
  echo "  下载到 $CALICO_YAML"
fi

echo ""
echo "=== 准备完成 ==="
echo "  containerd : $(containerd --version | awk '{print $3}')"
echo "  kubeadm    : $(kubeadm version -o short)"
echo "  kubelet    : $(kubelet --version)"
echo "  kubectl    : $(kubectl version --client -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
echo ""
echo "master 节点下一步：bash install-master.sh"
echo "worker 节点下一步：bash join-worker.sh <join-command>"
