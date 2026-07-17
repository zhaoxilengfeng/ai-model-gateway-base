#!/usr/bin/env bash
# warmup-images.sh — 将 llmdbenchmark harness 镜像预拉取到 K8s 节点
#
# harness pod 使用 ghcr.io/llm-d/llm-d-benchmark:v0.7.0（3GB），
# GPU 节点（h200-12-3）无法直连 ghcr.io，通过以下方式预拉取：
#
#   方式一（推荐）：daocloud mirror（国内直连速度快）
#     bash warmup-images.sh
#
#   方式二：privoxy HTTP 代理（通过 master 的 SOCKS5 转发）
#     PROXY_MODE=privoxy bash warmup-images.sh
#
# 拉取后自动将镜像复制到 k8s.io namespace，供 kubelet 使用。
#
# 用法：
#   bash warmup-images.sh                     # daocloud 方式（默认）
#   PROXY_MODE=privoxy bash warmup-images.sh  # 代理方式
#   TARGET_NODE=11.194.12.3 bash warmup-images.sh

set -euo pipefail

TARGET_NODE="${TARGET_NODE:-11.194.12.3}"
PROXY_MODE="${PROXY_MODE:-daocloud}"
BENCHMARK_IMAGE="ghcr.io/llm-d/llm-d-benchmark:v0.7.0"
DAOCLOUD_IMAGE="m.daocloud.io/ghcr.io/llm-d/llm-d-benchmark:v0.7.0"
MASTER_INTERNAL_IP="${MASTER_IP:-11.194.10.4}"
SOCKS5_PORT="${SOCKS5_PORT:-1080}"
PRIVOXY_PORT="${PRIVOXY_PORT:-8118}"

SSH="ssh -o StrictHostKeyChecking=no root@${TARGET_NODE}"

echo "=== warmup-images: 目标节点 ${TARGET_NODE} ==="
echo "  拉取方式: ${PROXY_MODE}"
echo "  镜像:     ${BENCHMARK_IMAGE}"
echo ""

# --- 检查是否已经存在 ---
if $SSH "ctr -n k8s.io image ls 2>/dev/null | grep -q llm-d-benchmark"; then
    echo "  ✓ 镜像已存在于 k8s.io namespace，跳过拉取"
    exit 0
fi

pull_via_daocloud() {
    echo "  使用 daocloud mirror 拉取..."
    if $SSH "ctr image ls 2>/dev/null | grep -q llm-d-benchmark"; then
        echo "  ✓ 镜像已在默认 namespace，直接复制到 k8s.io..."
    else
        $SSH "ctr images pull ${DAOCLOUD_IMAGE} 2>&1 | tail -5" || {
            echo "  [ERROR] daocloud 拉取失败，尝试代理方式"
            return 1
        }
    fi
}

pull_via_privoxy() {
    echo "  配置 privoxy 代理 (${MASTER_INTERNAL_IP}:${PRIVOXY_PORT})..."

    # 检查 privoxy 是否在 master 上运行
    if ! ss -tlnp 2>/dev/null | grep -q "${PRIVOXY_PORT}"; then
        echo "  启动 privoxy..."
        if ! command -v privoxy &>/dev/null; then
            echo "  [ERROR] privoxy 未安装，请运行: apt-get install -y privoxy"
            return 1
        fi
        cat > /etc/privoxy/config-custom.conf << EOF
listen-address  ${MASTER_INTERNAL_IP}:${PRIVOXY_PORT}
forward-socks5  /  127.0.0.1:${SOCKS5_PORT}  .
EOF
        chmod 644 /etc/privoxy/config-custom.conf
        nohup privoxy /etc/privoxy/config-custom.conf 2>/dev/null &
        sleep 2
    fi

    # 配置 GPU 节点 containerd HTTP proxy
    $SSH "
mkdir -p /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/containerd.service.d/http-proxy.conf << PROXYEOF
[Service]
Environment=\"HTTPS_PROXY=http://${MASTER_INTERNAL_IP}:${PRIVOXY_PORT}\"
Environment=\"HTTP_PROXY=http://${MASTER_INTERNAL_IP}:${PRIVOXY_PORT}\"
Environment=\"NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,11.0.0.0/8\"
PROXYEOF
systemctl daemon-reload
systemctl restart containerd
sleep 3
ctr images pull ${BENCHMARK_IMAGE} 2>&1 | tail -5
"
}

# --- 拉取镜像 ---
case "$PROXY_MODE" in
    daocloud) pull_via_daocloud || pull_via_privoxy ;;
    privoxy)  pull_via_privoxy ;;
    *)
        echo "[ERROR] 未知 PROXY_MODE: $PROXY_MODE (支持 daocloud|privoxy)"
        exit 1
        ;;
esac

# --- 复制到 k8s.io namespace ---
echo ""
echo "  复制镜像到 k8s.io namespace（供 kubelet 使用）..."
$SSH '
if ctr -n k8s.io image ls 2>/dev/null | grep -q llm-d-benchmark; then
    echo "  ✓ 已在 k8s.io namespace"
else
    IMG=$(ctr image ls 2>/dev/null | grep llm-d-benchmark | awk "{print \$1}" | head -1)
    if [[ -n "$IMG" ]]; then
        ctr image export - "$IMG" | ctr -n k8s.io image import - 2>&1 | tail -3
        echo "  ✓ 已导入到 k8s.io namespace"
    else
        echo "[ERROR] 未找到已拉取的镜像"
        exit 1
    fi
fi
'

echo ""
echo "  验证:"
$SSH "ctr -n k8s.io image ls 2>/dev/null | grep llm-d-benchmark || echo '[ERROR] 验证失败'"
echo ""
echo "=== 完成 ==="
