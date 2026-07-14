#!/bin/bash
# download-modelscope.sh — 从 ModelScope 下载模型
set -e

MODEL_REPO="${MODEL_REPO:-ZhipuAI/GLM-5.2-FP8}"
LOCAL_DIR="${LOCAL_DIR:-/home/data/model/GLM-5.2-FP8}"
MS_TOKEN="${MS_TOKEN:-}"

echo "=== Download model from ModelScope ==="
echo "  repo    : $MODEL_REPO"
echo "  local   : $LOCAL_DIR"

mkdir -p "$LOCAL_DIR"

# 确保 modelscope 已安装
if ! python3 -c 'import modelscope' &>/dev/null; then
  echo "=== Installing modelscope ==="
  pip3 install --break-system-packages -q modelscope
fi

# 下载模型
MODELSCOPE_API_TOKEN="${MS_TOKEN}" \
python3 - <<PYEOF
from modelscope import snapshot_download

snapshot_download(
    model_id="${MODEL_REPO}",
    local_dir="${LOCAL_DIR}",
    ignore_patterns=["*.gitattributes", "README*"],
)
print("Download complete: ${LOCAL_DIR}")
PYEOF

echo ""
echo "=== 下载完成 ==="
echo "  路径: $LOCAL_DIR"
du -sh "$LOCAL_DIR" 2>/dev/null || true
