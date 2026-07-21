#!/bin/bash
# sync-images-to-node.sh — 将本机 k8s.io namespace 中的 llm-d 路由网关镜像
#                          通过 ctr export → scp → ctr import 同步到指定节点
#
# 用法:
#   bash sync-images-to-node.sh [TARGET_NODE]
#
# 默认目标节点: 11.194.12.3，可通过参数或环境变量 TARGET_NODE 覆盖
set -euo pipefail

TARGET_NODE="${1:-${TARGET_NODE:-11.194.12.3}}"
TMP_DIR="${TMP_DIR:-/tmp}"

# ── 需要同步的镜像，每行一个: "tar文件名|镜像地址" ──────────────────────────
declare -a IMAGES=(
  "llm-d-router-endpoint-picker.tar|ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0"
  "agentgateway.tar|ghcr.io/agentgateway/agentgateway:v1.3.1"
  "agentgateway-controller.tar|ghcr.io/agentgateway/controller:v1.3.1"
  "vllm-openai-cpu.tar|docker.io/vllm/vllm-openai-cpu:v0.23.0"
  "vllm-openai.tar|docker.io/vllm/vllm-openai:v0.23.0"
)

SSH_OPTS="-o StrictHostKeyChecking=no"

echo "=== sync-images-to-node: 目标节点 ${TARGET_NODE} ==="

# 预检查本机 /tmp 可用空间（至少 20G，GPU 镜像可达 10G+）
AVAIL_KB=$(df -k "${TMP_DIR}" | awk 'NR==2{print $4}')
if [[ "${AVAIL_KB}" -lt 20971520 ]]; then
  echo "WARNING: ${TMP_DIR} 可用空间不足 20G（当前 $(( AVAIL_KB / 1024 / 1024 ))G），大镜像导出可能失败" >&2
fi

for item in "${IMAGES[@]}"; do
  TAR_NAME="${item%%|*}"
  IMAGE="${item#*|}"
  TAR_PATH="${TMP_DIR}/${TAR_NAME}"

  echo ""
  echo "--- [${IMAGE}] ---"

  # 检查目标节点是否已有该镜像
  if ssh ${SSH_OPTS} "root@${TARGET_NODE}" \
      "ctr -n k8s.io image ls | grep -qF '${IMAGE}'"; then
    echo "  已存在，跳过"
    continue
  fi

  # 1. 导出（先清除可能损坏的残留文件）
  rm -f "${TAR_PATH}"
  echo "  [1/3] 导出 -> ${TAR_PATH} ..."
  ctr -n k8s.io image export "${TAR_PATH}" "${IMAGE}"
  echo "  导出完成: $(du -sh "${TAR_PATH}" | cut -f1)"

  # 2. 传输
  echo "  [2/3] SCP -> ${TARGET_NODE}:${TMP_DIR}/ ..."
  scp ${SSH_OPTS} "${TAR_PATH}" "root@${TARGET_NODE}:${TMP_DIR}/"
  echo "  传输完成"

  # 3. 导入并清理
  echo "  [3/3] 在 ${TARGET_NODE} 上导入 ..."
  ssh ${SSH_OPTS} "root@${TARGET_NODE}" \
    "ctr -n k8s.io image import ${TMP_DIR}/${TAR_NAME} && rm -f ${TMP_DIR}/${TAR_NAME}"
  echo "  导入完成"

  rm -f "${TAR_PATH}"
done

echo ""
echo "=== 同步完成，验证 ${TARGET_NODE} 上的镜像 ==="
ssh ${SSH_OPTS} "root@${TARGET_NODE}" \
  "ctr -n k8s.io image ls | grep -E 'llm-d-router|vllm-openai|agentgateway' | awk '{print \$1}'"
