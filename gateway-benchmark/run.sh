#!/usr/bin/env bash
# 推理网关对比测试入口
# 用法: ./run.sh --gateway <llmd|aibrix> [OPTIONS]
#
# 选项:
#   --gateway    llmd | aibrix （必填）
#   --harness    inference-perf | guidellm  （默认读 config.yaml defaults.harness）
#   --workload   profiles/<harness>/ 下的文件名，不含 .in 后缀（默认读 config.yaml）
#   --experiment experiments/ 下的文件名（可选，不传则用 profile 内置阶梯）
#   --parallelism 并行 harness pod 数（默认 1）
#   --proxy      启用代理，如 socks5h://127.0.0.1:1080（默认不使用）
#   --dry-run    仅打印命令，不实际执行
#   --spec       llmdbenchmark --spec 参数（默认 gpu）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

# --- 依赖检查 ---
if ! command -v llmdbenchmark &>/dev/null; then
    echo "[ERROR] 'llmdbenchmark' not found. Run: source /root/llm-d-benchmark/.venv/bin/activate" >&2
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    echo "[ERROR] 'python3' not found." >&2
    exit 1
fi

# 用 python3 读取 YAML（不依赖系统 yq）
yaml_get() {
    python3 -c "
import sys, yaml
with open('$CONFIG') as f:
    d = yaml.safe_load(f)
keys = '$1'.lstrip('.').split('.')
v = d
for k in keys:
    v = v[k]
print(v)
"
}

# --- 参数解析 ---
GATEWAY=""
HARNESS=""
WORKLOAD=""
EXPERIMENT=""
PARALLELISM=""
PROXY=""
DRY_RUN=false
SPEC="gpu"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gateway)    GATEWAY="$2";      shift 2 ;;
        --harness)    HARNESS="$2";      shift 2 ;;
        --workload)   WORKLOAD="$2";     shift 2 ;;
        --experiment) EXPERIMENT="$2";   shift 2 ;;
        --parallelism) PARALLELISM="$2"; shift 2 ;;
        --proxy)      PROXY="$2";        shift 2 ;;
        --spec)       SPEC="$2";         shift 2 ;;
        --dry-run)    DRY_RUN=true;      shift ;;
        *)            EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$GATEWAY" ]]; then
    echo "Usage: $0 --gateway <llmd|aibrix> [--harness ...] [--workload ...] [--experiment ...] [--dry-run]"
    exit 1
fi

if [[ "$GATEWAY" != "llmd" && "$GATEWAY" != "aibrix" ]]; then
    echo "[ERROR] --gateway must be 'llmd' or 'aibrix'" >&2
    exit 1
fi

# --- 读取 config.yaml ---
ENDPOINT_URL=$(yaml_get ".${GATEWAY}.endpoint_url")
MODEL=$(yaml_get        ".${GATEWAY}.model")
NAMESPACE=$(yaml_get    ".${GATEWAY}.namespace")

if [[ "$ENDPOINT_URL" == *"PLACEHOLDER"* || "$MODEL" == *"PLACEHOLDER"* || "$NAMESPACE" == *"PLACEHOLDER"* ]]; then
    echo "[ERROR] config.yaml 中还有未替换的 PLACEHOLDER，请先编辑 config.yaml" >&2
    exit 1
fi

HARNESS="${HARNESS:-$(yaml_get '.defaults.harness')}"
WORKLOAD="${WORKLOAD:-$(yaml_get '.defaults.workload')}"
PARALLELISM="${PARALLELISM:-$(yaml_get '.defaults.parallelism')}"

# 移除 .in 后缀（用户可以带或不带）
WORKLOAD="${WORKLOAD%.in}"

# --- 构造工作目录（按时间戳隔离） ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORKSPACE="${SCRIPT_DIR}/results/${GATEWAY}/${HARNESS}/${TIMESTAMP}"
mkdir -p "$WORKSPACE"

# --- 构造 llmdbenchmark 命令 ---
# profiles 目录指向本项目自己的 profiles，传入绝对路径
PROFILE_DIR="${SCRIPT_DIR}/profiles/${HARNESS}"
PROFILE_FILE="${PROFILE_DIR}/${WORKLOAD}.in"

if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "[ERROR] profile 不存在: $PROFILE_FILE" >&2
    echo "可用 profiles:" >&2
    ls "${PROFILE_DIR}/"*.in 2>/dev/null | xargs -n1 basename >&2
    exit 1
fi

CMD=(
    llmdbenchmark
    --spec "${SPEC}"
    --workspace "${WORKSPACE}"
    run
    --namespace "${NAMESPACE}"
    --endpoint-url "${ENDPOINT_URL}"
    --model "${MODEL}"
    --harness "${HARNESS}"
    --workload "${PROFILE_FILE}"
    --parallelism "${PARALLELISM}"
)

if [[ -n "$EXPERIMENT" ]]; then
    EXP_FILE="${SCRIPT_DIR}/experiments/${EXPERIMENT}"
    if [[ ! -f "$EXP_FILE" ]]; then
        echo "[ERROR] experiment 文件不存在: $EXP_FILE" >&2
        echo "可用 experiments:" >&2
        ls "${SCRIPT_DIR}/experiments/"*.yaml | xargs -n1 basename >&2
        exit 1
    fi
    CMD+=(--experiments "${EXP_FILE}")
fi

CMD+=("${EXTRA_ARGS[@]}")

# --- 执行 ---
echo "=========================================="
echo "  网关:       $GATEWAY"
echo "  Endpoint:   $ENDPOINT_URL"
echo "  Model:      $MODEL"
echo "  Namespace:  $NAMESPACE"
echo "  Harness:    $HARNESS"
echo "  Workload:   $WORKLOAD"
echo "  Experiment: ${EXPERIMENT:-（无，使用 profile 内置阶梯）}"
echo "  Parallelism: $PARALLELISM"
echo "  Proxy:      ${PROXY:-（未启用）}"
echo "  结果目录:   $WORKSPACE"
echo "=========================================="
echo ""
echo "命令: ${CMD[*]}"
echo ""

if $DRY_RUN; then
    echo "[DRY-RUN] 未执行，退出。"
    exit 0
fi

if [[ -n "$PROXY" ]]; then
    export https_proxy="$PROXY"
    export http_proxy="$PROXY"
fi

"${CMD[@]}"
echo ""
echo "[完成] 结果保存至: $WORKSPACE"
