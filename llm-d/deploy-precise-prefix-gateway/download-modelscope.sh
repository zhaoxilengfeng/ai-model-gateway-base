#!/bin/bash
# download-modelscope.sh — 从 ModelScope 下载模型
set -e

MODEL_REPO="${MODEL_REPO:-ZhipuAI/GLM-5.2-FP8}"
LOCAL_DIR="${LOCAL_DIR:-/home/data/model/GLM-5.2-FP8}"
MS_TOKEN="${MS_TOKEN:-}"
VENV_DIR="${VENV_DIR:-/root/.venv/modelscope}"

echo "=== Download model from ModelScope ==="
echo "  repo    : $MODEL_REPO"
echo "  local   : $LOCAL_DIR"
echo "  venv    : $VENV_DIR"

mkdir -p "$LOCAL_DIR"

# 创建虚拟环境（如不存在）
if [ ! -f "$VENV_DIR/bin/activate" ]; then
  echo "=== Creating venv: $VENV_DIR ==="
  python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

# 安装 modelscope（仅在 venv 内）
if ! python3 -c 'import modelscope' &>/dev/null; then
  echo "=== Installing modelscope into venv ==="
  pip install -q modelscope
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

deactivate

echo ""
echo "=== 下载完成 ==="
echo "  路径: $LOCAL_DIR"
du -sh "$LOCAL_DIR" 2>/dev/null || true
