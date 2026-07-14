#!/bin/bash
# download-model.sh — 通过 socks5 代理从 HuggingFace 下载模型
set -e

MODEL_REPO="${MODEL_REPO:-Qwen/Qwen2.5-7B-Instruct}"
MODEL_CACHE="${MODEL_CACHE:-/root/models/hub}"
HF_TOKEN="${HF_TOKEN:-}"
PROXY="${HTTPS_PROXY:-socks5h://127.0.0.1:1080}"

# 将 model repo 转换为本地目录名，如 Qwen/Qwen2.5-7B-Instruct -> models--Qwen--Qwen2.5-7B-Instruct
LOCAL_DIR_NAME="models--$(echo "$MODEL_REPO" | sed 's|/|--|g')"
LOCAL_DIR="$MODEL_CACHE/$LOCAL_DIR_NAME"

echo "=== Download model from HuggingFace ==="
echo "  repo    : $MODEL_REPO"
echo "  local   : $LOCAL_DIR"
echo "  proxy   : $PROXY"

mkdir -p "$MODEL_CACHE"

# 确保 huggingface_hub 已安装
if ! command -v hf &>/dev/null; then
  echo "=== Installing huggingface_hub ==="
  pip3 install --break-system-packages -q PySocks huggingface_hub
fi

# 下载模型（hf 命令，新版 huggingface_hub）
HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}" \
HTTPS_PROXY="$PROXY" \
HTTP_PROXY="$PROXY" \
hf download "$MODEL_REPO" \
  --local-dir "$LOCAL_DIR"

echo ""
echo "=== 下载完成 ==="
echo "  路径: $LOCAL_DIR"
du -sh "$LOCAL_DIR" 2>/dev/null || true
