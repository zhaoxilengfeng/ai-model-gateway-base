#!/usr/bin/env bash
# setup.sh — 一键准备 gateway-benchmark 运行环境
#
# 执行内容：
#   1. 检查依赖（kubectl、llmdbenchmark）
#   2. 在所有节点上创建 hostPath 目录
#   3. 创建 PV（若不存在）
#   4. 拷贝 tokenizer 文件到 PVC 并同步到所有节点
#
# 用法：
#   bash setup.sh
#   SNAPSHOT=/path/to/model/snapshot bash setup.sh   # 指定模型 snapshot 路径

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 配置 ---
PV_NAME="${PV_NAME:-llmdbench-workload-pv}"
PV_SIZE="${PV_SIZE:-20Gi}"
HOSTPATH="${HOSTPATH:-/mnt/llmdbench-workload-pvc}"
SNAPSHOT="/root/models/hub/models--Qwen--Qwen2.5-7B-Instruct"

echo "========================================"
echo "  Gateway Benchmark 环境初始化"
echo "========================================"
echo ""

# --- 1. 检查依赖 ---
echo "▶ 检查依赖..."
MISSING=()
command -v kubectl &>/dev/null || MISSING+=("kubectl")

# 检查 llmdbenchmark
if ! command -v llmdbenchmark &>/dev/null; then
    for venv in /root/llm-d-benchmark/.venv/bin/activate "${SCRIPT_DIR}/../.venv/bin/activate"; do
        [[ -f "$venv" ]] && source "$venv" && break
    done
fi
command -v llmdbenchmark &>/dev/null || MISSING+=("llmdbenchmark（运行: cd /root/llm-d-benchmark && bash install.sh --no-uv -y）")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[ERROR] 缺少依赖: ${MISSING[*]}" >&2
    exit 1
fi
echo "  ✓ kubectl、llmdbenchmark 均可用"

# --- 2. 获取所有节点 IP ---
echo ""
echo "▶ 获取集群节点..."
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
if [[ -z "$NODE_IPS" ]]; then
    echo "[WARN] 无法获取节点 IP，跳过远端同步"
fi
echo "  节点: ${NODE_IPS:-（未获取）}"

# --- 3. 在所有节点上创建 hostPath 目录 ---
echo ""
echo "▶ 创建 hostPath 目录 $HOSTPATH ..."
mkdir -p "${HOSTPATH}"
echo "  ✓ 本机: ${HOSTPATH}"

for node_ip in $NODE_IPS; do
    # 跳过本机（比较 IP）
    if ip addr show 2>/dev/null | grep -q "$node_ip"; then
        continue
    fi
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${node_ip}" \
        "mkdir -p ${HOSTPATH}" 2>/dev/null; then
        echo "  ✓ ${node_ip}: ${HOSTPATH}"
    else
        echo "  ⚠ ${node_ip}: SSH 失败，请手动执行: ssh root@${node_ip} 'mkdir -p ${HOSTPATH}'"
    fi
done

# --- 4. 创建 PV（若不存在）---
echo ""
echo "▶ 检查 PersistentVolume..."
PV_STATUS=$(kubectl get pv "${PV_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$PV_STATUS" == "NotFound" ]]; then
    echo "  PV '${PV_NAME}' 不存在，创建中..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: ${PV_SIZE}
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: ${HOSTPATH}
    type: DirectoryOrCreate
EOF
    echo "  ✓ PV '${PV_NAME}' 已创建"
elif [[ "$PV_STATUS" == "Released" ]]; then
    echo "  PV '${PV_NAME}' 处于 Released 状态，释放 claimRef..."
    kubectl patch pv "${PV_NAME}" -p '{"spec":{"claimRef":null}}' &>/dev/null
    echo "  ✓ PV '${PV_NAME}' 已释放，可重新绑定"
else
    echo "  ✓ PV '${PV_NAME}' 已存在（状态: ${PV_STATUS}）"
fi

# --- 5. 拷贝 tokenizer 文件 ---
echo ""
echo "▶ 准备 tokenizer 文件..."
TOKENIZER_FILES=(tokenizer.json tokenizer_config.json vocab.json merges.txt)
TOKENIZER_DST="${HOSTPATH}/tokenizer"
mkdir -p "${TOKENIZER_DST}"

if [[ ! -d "$SNAPSHOT" ]]; then
    echo "  [WARN] 找不到 snapshot 目录: $SNAPSHOT"
    echo "  请手动设置 SNAPSHOT 环境变量指向模型 snapshot 路径"
    echo "  示例: SNAPSHOT=/path/to/model bash setup.sh"
else
    COPIED=0
    for f in "${TOKENIZER_FILES[@]}"; do
        src="${SNAPSHOT}/${f}"
        if [[ -f "$src" ]]; then
            cp "$src" "${TOKENIZER_DST}/"
            COPIED=$((COPIED + 1))
        fi
    done
    echo "  ✓ 本机: 拷贝了 ${COPIED} 个 tokenizer 文件到 ${TOKENIZER_DST}"

    # 同步到远端节点
    for node_ip in $NODE_IPS; do
        if ip addr show 2>/dev/null | grep -q "$node_ip"; then
            continue
        fi
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${node_ip}" \
            "mkdir -p ${HOSTPATH}/tokenizer" 2>/dev/null && \
           scp -o StrictHostKeyChecking=no -q \
            "${TOKENIZER_DST}"/* "root@${node_ip}:${HOSTPATH}/tokenizer/" 2>/dev/null; then
            echo "  ✓ ${node_ip}: tokenizer 文件已同步"
        else
            echo "  ⚠ ${node_ip}: 同步失败，请手动执行:"
            echo "    scp ${TOKENIZER_DST}/* root@${node_ip}:${HOSTPATH}/tokenizer/"
        fi
    done
fi

# --- 完成 ---
echo ""
echo "========================================"
echo "  初始化完成！"
echo ""
echo "  下一步："
echo "  1. 编辑 config.yaml 填写 endpoint_url、model、namespace"
echo "  2. 运行快速验通: ./run_llmd.sh --workload sanity.yaml"
echo "  3. 运行完整压测: ./run_llmd.sh"
echo "========================================"
