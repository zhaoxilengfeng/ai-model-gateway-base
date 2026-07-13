#!/usr/bin/env bash
# warmup-images.sh — 将 llmdbenchmark harness 镜像预推到阿里云，加速节点拉取
#
# llmdbenchmark 在 K8s 内起 harness pod，使用 ghcr.io/llm-d/llm-d-benchmark:v0.7.0。
# 首次运行时节点需从 ghcr.io 拉取，速度较慢（可能超时）。
# 本脚本通过代理将镜像复制到阿里云 registry，之后节点从阿里云拉取速度更快。
#
# 用法:
#   bash warmup-images.sh                         # 使用默认配置
#   PROXY=socks5://127.0.0.1:1080 bash warmup-images.sh
#   ALIYUN_NS=your-namespace bash warmup-images.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLMDBENCH_DIR="${LLMDBENCH_DIR:-/root/llm-d-benchmark}"

PROXY="${PROXY:-socks5://127.0.0.1:1080}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
ALIYUN_NS="${ALIYUN_NS:-airouter}"
DOCKER_AUTH="${DOCKER_AUTH:-${HOME}/.docker/config.json}"

BENCHMARK_IMAGE="ghcr.io/llm-d/llm-d-benchmark:v0.7.0"
ALIYUN_IMAGE="${ALIYUN_REGISTRY}/${ALIYUN_NS}/llm-d-benchmark:v0.7.0"

# 检查依赖
for cmd in skopeo kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERROR] '$cmd' not found" >&2
        exit 1
    fi
done

# --- 1. 复制镜像到阿里云 ---
echo "=== 1. 复制 harness 镜像到阿里云 ==="
echo "  源:    $BENCHMARK_IMAGE"
echo "  目标:  $ALIYUN_IMAGE"
echo "  代理:  $PROXY"
echo ""

if https_proxy="$PROXY" skopeo inspect "docker://${ALIYUN_IMAGE}" \
    --authfile "$DOCKER_AUTH" &>/dev/null; then
    echo "  镜像已存在，跳过复制。"
else
    echo "  正在复制（镜像较大，约需 3-5 分钟）..."
    https_proxy="$PROXY" skopeo copy \
        "docker://${BENCHMARK_IMAGE}" \
        "docker://${ALIYUN_IMAGE}" \
        --authfile "$DOCKER_AUTH"
    echo "  复制完成: $ALIYUN_IMAGE"
fi

# --- 2. Patch 节点 containerd 配置，将 ghcr.io/llm-d 重定向到阿里云 ---
echo ""
echo "=== 2. 配置节点 containerd 镜像 mirror ==="
echo "  需要在每个 worker 节点上配置 /etc/containerd/certs.d/ghcr.io/llm-d/hosts.toml"
echo ""

# 生成 mirror 配置内容
MIRROR_CONFIG=$(cat <<EOF
server = "https://ghcr.io"

[host."https://${ALIYUN_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  [host."https://${ALIYUN_REGISTRY}".header]
    authorization = ""
EOF
)

echo "  建议在各 worker 节点执行以下命令："
echo ""
echo "  mkdir -p /etc/containerd/certs.d/ghcr.io/llm-d"
echo "  cat > /etc/containerd/certs.d/ghcr.io/llm-d/hosts.toml << 'HOSTSEOF'"
echo "$MIRROR_CONFIG"
echo "  HOSTSEOF"
echo "  systemctl reload containerd"
echo ""

# 检查是否有 kubectl exec 权限，可以直接远程配置
NODES=$(kubectl get nodes --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep -v "$(hostname)" || true)
if [[ -n "$NODES" ]]; then
    echo "  检测到以下节点（本机不含）："
    echo "$NODES" | sed 's/^/    /'
    echo ""
    echo "  如果节点有 SSH 访问权限，可用以下命令批量配置："
    echo ""
    for node_ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
        echo "  ssh root@${node_ip} 'mkdir -p /etc/containerd/certs.d/ghcr.io && ...'"
    done
fi

echo ""
echo "=== 完成 ==="
echo "  阿里云镜像: $ALIYUN_IMAGE"
echo "  节点配置 containerd mirror 后，后续 harness pod 可从阿里云快速拉取。"
