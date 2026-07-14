#!/usr/bin/env bash
# 推理网关对比测试入口
# 用法: ./run.sh --gateway <llmd|aibrix> [OPTIONS]
#
# 选项:
#   --gateway         llmd | aibrix （必填）
#   --harness         inference-perf | guidellm | vllm-benchmark  （默认读 config.yaml defaults.harness）
#   --workload        profiles/<harness>/ 下的文件名，不含 .in 后缀（默认读 config.yaml）
#   --experiment      experiments/ 下的文件名（可选，不传则用 profile 内置阶梯）
#   --parallelism     并行 harness pod 数（默认 1）
#   --proxy           启用代理，如 socks5h://127.0.0.1:1080（默认不使用）
#   --spec            llmdbenchmark --spec 参数（默认 gpu）
#   --monitoring      启用 vLLM metrics 采集和可视化（采集 KV cache 命中率等指标）
#   --analyze         测试完成后本地生成分析图表
#   --skip            仅收集已有 PVC 上的结果，不重新跑 harness
#   --debug           harness pod 以 sleep infinity 启动，用于调试
#   --metrics-port    vLLM metrics 端口（默认 8000，llmdbenchmark 默认 8200 需覆盖）
#   --dry-run         仅打印命令，不实际执行
#   --list-profiles   列出可用 profiles 后退出
#   --list-experiments 列出可用 experiments 后退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

# llm-d-benchmark 仓库根目录（--base-dir 和 venv 的来源）
LLMDBENCH_DIR="${LLMDBENCH_DIR:-/root/llm-d-benchmark}"

# --- llmdbenchmark 自动查找 ---
if ! command -v llmdbenchmark &>/dev/null; then
    VENV_CANDIDATES=(
        "${LLMDBENCH_DIR}/.venv/bin/activate"
        "${SCRIPT_DIR}/../.venv/bin/activate"
    )
    for venv in "${VENV_CANDIDATES[@]}"; do
        if [[ -f "$venv" ]]; then
            # shellcheck source=/dev/null
            source "$venv"
            break
        fi
    done
fi

if ! command -v llmdbenchmark &>/dev/null; then
    echo "[ERROR] llmdbenchmark 未找到。请先运行：" >&2
    echo "  cd ${LLMDBENCH_DIR} && bash install.sh --no-uv -y" >&2
    echo "  source ${LLMDBENCH_DIR}/.venv/bin/activate" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "[ERROR] python3 未找到" >&2
    exit 1
fi

# 用 python3 读取 YAML（不依赖系统 yq）
yaml_get() {
    local key="$1"
    python3 -c "
import yaml
with open('${CONFIG}') as f:
    d = yaml.safe_load(f)
keys = '${key}'.lstrip('.').split('.')
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
MONITORING=false
ANALYZE=false
SKIP=false
DEBUG=false
METRICS_PORT=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gateway)          GATEWAY="$2";      shift 2 ;;
        --harness)          HARNESS="$2";      shift 2 ;;
        --workload)         WORKLOAD="$2";     shift 2 ;;
        --experiment)       EXPERIMENT="$2";   shift 2 ;;
        --parallelism)      PARALLELISM="$2";  shift 2 ;;
        --proxy)            PROXY="$2";        shift 2 ;;
        --spec)             SPEC="$2";         shift 2 ;;
        --metrics-port)     METRICS_PORT="$2"; shift 2 ;;
        --monitoring)       MONITORING=true;   shift ;;
        --analyze)          ANALYZE=true;      shift ;;
        --skip)             SKIP=true;         shift ;;
        --debug)            DEBUG=true;        shift ;;
        --dry-run)          DRY_RUN=true;      shift ;;
        --list-profiles)
            echo "=== 可用 Profiles ==="
            for dir in "${SCRIPT_DIR}/profiles/"/*/; do
                harness=$(basename "$dir")
                echo "  [$harness]"
                ls "$dir"*.in 2>/dev/null | xargs -n1 basename | sed 's/^/    /'
            done
            exit 0 ;;
        --list-experiments)
            echo "=== 可用 Experiments ==="
            ls "${SCRIPT_DIR}/experiments/"*.yaml | xargs -n1 basename | sed 's/^/  /'
            exit 0 ;;
        *)                  EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$GATEWAY" ]]; then
    echo "Usage: $0 --gateway <llmd|aibrix> [OPTIONS]"
    echo ""
    echo "  --gateway         llmd | aibrix  （必填）"
    echo "  --harness         inference-perf | guidellm | vllm-benchmark"
    echo "  --workload        profile 文件名（不含 .in）"
    echo "  --experiment      experiment 文件名"
    echo "  --parallelism     并行 pod 数（默认 1）"
    echo "  --proxy           代理地址（默认不使用）"
    echo "  --spec            llmdbenchmark --spec（默认 gpu）"
    echo "  --monitoring      启用 vLLM metrics 采集（KV cache 命中率等）"
    echo "  --analyze         测试完成后本地生成分析图表"
    echo "  --skip            仅收集已有结果，不重跑 harness"
    echo "  --debug           harness pod 以 sleep infinity 启动（调试用）"
    echo "  --metrics-port    vLLM metrics 端口（默认 8000）"
    echo "  --dry-run         只打印命令"
    echo "  --list-profiles   列出可用 profiles"
    echo "  --list-experiments 列出可用 experiments"
    exit 1
fi

if [[ "$GATEWAY" != "llmd" && "$GATEWAY" != "aibrix" ]]; then
    echo "[ERROR] --gateway 必须是 llmd 或 aibrix" >&2
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
DATA_ACCESS_TIMEOUT="$(yaml_get '.defaults.data_access_timeout' 2>/dev/null || echo '600')"
# metrics 端口：我们的 vLLM 在 8000 暴露 metrics，llmdbenchmark 默认 8200
METRICS_PORT="${METRICS_PORT:-$(yaml_get '.defaults.metrics_port' 2>/dev/null || echo '8000')}"

# --- PV 自动释放（Released 状态的 PV 需清除 claimRef 才能重新绑定）---
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    kubectl patch pv "$pv" -p '{"spec":{"claimRef":null}}' &>/dev/null && \
        echo "[INFO] PV $pv 已释放，可重新绑定" || true
done

# 移除 .in 后缀（用户可以带或不带）
WORKLOAD="${WORKLOAD%.in}"

# --- Profile 文件定位 ---
PROFILE_DIR="${SCRIPT_DIR}/profiles/${HARNESS}"
PROFILE_FILE="${PROFILE_DIR}/${WORKLOAD}.in"

if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "[ERROR] profile 不存在: $PROFILE_FILE" >&2
    echo "可用 profiles（${HARNESS}）:" >&2
    ls "${PROFILE_DIR}/"*.in 2>/dev/null | xargs -n1 basename | sed 's/^/  /' >&2 || true
    echo "使用 --list-profiles 查看全部" >&2
    exit 1
fi

# --- Experiment 文件定位 ---
EXP_ARG=()
if [[ -n "$EXPERIMENT" ]]; then
    if [[ "$EXPERIMENT" == */* ]]; then
        EXP_FILE="$EXPERIMENT"
    else
        EXP_FILE="${SCRIPT_DIR}/experiments/${EXPERIMENT}"
    fi
    if [[ ! -f "$EXP_FILE" ]]; then
        echo "[ERROR] experiment 文件不存在: $EXP_FILE" >&2
        echo "可用 experiments:" >&2
        ls "${SCRIPT_DIR}/experiments/"*.yaml | xargs -n1 basename | sed 's/^/  /' >&2
        exit 1
    fi
    EXP_ARG=(--experiments "${EXP_FILE}")
fi

# --- 构造工作目录（按时间戳隔离） ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORKSPACE="${SCRIPT_DIR}/results/${GATEWAY}/${HARNESS}/${TIMESTAMP}"
mkdir -p "$WORKSPACE"

# --- 构造命令 ---
CMD=(
    llmdbenchmark
    --spec "${SPEC}"
    --base-dir "${LLMDBENCH_DIR}"
    --workspace "${WORKSPACE}"
    run
    --namespace "${NAMESPACE}"
    --endpoint-url "${ENDPOINT_URL}"
    --model "${MODEL}"
    --harness "${HARNESS}"
    --workload "${WORKLOAD}"
    --workload-file-path "${PROFILE_FILE}"
    --parallelism "${PARALLELISM}"
    --data-access-timeout "${DATA_ACCESS_TIMEOUT}"
    # 覆盖 metrics 端口（llmdbenchmark 默认 8200，我们的 vLLM 在 8000）
    --overrides "vllmCommon.metricsPort=${METRICS_PORT}"
    "${EXP_ARG[@]}"
)

$MONITORING && CMD+=(--monitoring)
$ANALYZE   && CMD+=(--analyze)
$SKIP      && CMD+=(-z)
$DEBUG     && CMD+=(-d)

CMD+=("${EXTRA_ARGS[@]}")

# --- 打印摘要 ---
echo "=========================================="
echo "  网关:        $GATEWAY"
echo "  Endpoint:    $ENDPOINT_URL"
echo "  Model:       $MODEL"
echo "  Namespace:   $NAMESPACE"
echo "  Harness:     $HARNESS"
echo "  Workload:    $WORKLOAD"
echo "  Experiment:  ${EXPERIMENT:-（无，使用 profile 内置阶梯）}"
echo "  Parallelism: $PARALLELISM"
echo "  Monitoring:  $MONITORING"
echo "  Analyze:     $ANALYZE"
echo "  Proxy:       ${PROXY:-（未启用）}"
echo "  结果目录:    $WORKSPACE"
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
