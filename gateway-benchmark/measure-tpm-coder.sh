#!/usr/bin/env bash
# measure-tpm-coder.sh — 用真实 Qwen Coder Trace 数据测量 TPM 上限
#
# 与 measure-tpm.sh 的区别：
#   - data 使用 weka_trace_replay（真实代码补全流量），而非合成数据
#   - ignore_trace_delays: true，忽略时间戳限速，让并发数真正控制 GPU 压力
#   - api.type: chat（coder trace 是多轮对话格式）
#   - 默认 SLO 2000ms（编码场景 input 长，TTFT 天然更高）
#
# 数据集路径：/mnt/llmdbench-workload-pvc/datasets/qwen-coder/converted/
# 如未准备好，参考 RUNBOOK 第 7 节下载并转换。
#
# 用法：
#   bash measure-tpm-coder.sh                          # 默认参数
#   bash measure-tpm-coder.sh --concurrency 32,64,128,200,300
#   bash measure-tpm-coder.sh --slo 1500
#   bash measure-tpm-coder.sh --trace-dir /path/to/converted
#   bash measure-tpm-coder.sh --dry-run

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

# --- 默认参数 ---
CONCURRENCY_STEPS="${CONCURRENCY:-32,64,128,200,300}"
REQUESTS_PER_STEP="${REQUESTS:-300}"
TTFT_P99_SLO="${SLO:-2000}"
TRACE_DIR="${TRACE_DIR:-/requests/datasets/qwen-coder/converted}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency)  CONCURRENCY_STEPS="$2"; shift 2 ;;
    --requests)     REQUESTS_PER_STEP="$2"; shift 2 ;;
    --slo)          TTFT_P99_SLO="$2"; shift 2 ;;
    --trace-dir)    TRACE_DIR="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

yaml_get() {
  python3 -c "
import yaml
with open('${CONFIG}') as f: d = yaml.safe_load(f)
keys = '$1'.lstrip('.').split('.')
v = d
for k in keys: v = v[k]
print(v)
"
}

ENDPOINT=$(yaml_get '.llmd.endpoint_url')
MODEL=$(yaml_get '.llmd.model')
NAMESPACE=$(yaml_get '.llmd.namespace')

echo "=============================================="
echo "  TPM 上限测量 — Qwen Coder Trace（真实数据）"
echo "  Endpoint:    $ENDPOINT"
echo "  Model:       $MODEL"
echo "  并发阶梯:    $CONCURRENCY_STEPS"
echo "  每阶段请求:  $REQUESTS_PER_STEP"
echo "  Trace 目录:  $TRACE_DIR"
echo "  max_model_len: $MAX_MODEL_LEN"
echo "  TTFT p99 SLO: ${TTFT_P99_SLO}ms"
echo "=============================================="

source /root/llm-d-benchmark/.venv/bin/activate

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORKSPACE="${SCRIPT_DIR}/results/llmd/inference-perf/tpm_coder_${TIMESTAMP}"
mkdir -p "$WORKSPACE"
PROFILE_FILE="${WORKSPACE}/tpm_coder_profile.yaml.in"

STAGES=""
IFS=',' read -ra STEPS <<< "$CONCURRENCY_STEPS"
for c in "${STEPS[@]}"; do
  STAGES="${STAGES}
    - concurrency_level: ${c}
      num_requests: ${REQUESTS_PER_STEP}"
done

cat > "$PROFILE_FILE" << EOF
load:
  type: concurrent
  stages:${STAGES}
api:
  type: chat
  streaming: true
server:
  type: vllm
  model_name: REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL
  base_url: REPLACE_ENV_LLMDBENCH_HARNESS_STACK_ENDPOINT_URL
  ignore_eos: true
tokenizer:
  pretrained_model_name_or_path: /requests/tokenizer
data:
  type: weka_trace_replay
  weka_trace_replay:
    trace_directory: ${TRACE_DIR}
    use_static_model: true
    static_model_name: REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL
    default_block_size: 16
    default_max_tokens: 512
    max_model_len: ${MAX_MODEL_LEN}
    skip_invalid_files: true
    ignore_trace_delays: true
    trace_idle_gap_cap_seconds: 5.0
report:
  request_lifecycle:
    summary: true
    per_stage: true
    per_request: true
storage:
  local_storage:
    path: /workspace
EOF

if $DRY_RUN; then
  echo "[DRY-RUN] profile 已生成: $PROFILE_FILE"
  cat "$PROFILE_FILE"
  exit 0
fi

# 释放已有 PV
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  kubectl patch pv "$pv" -p '{"spec":{"claimRef":null}}' &>/dev/null || true
done

echo ""
echo "[$(date +%H:%M:%S)] 开始测试..."
llmdbenchmark \
  --spec gpu \
  --base-dir /root/llm-d-benchmark \
  --workspace "$WORKSPACE" \
  run \
  --namespace "$NAMESPACE" \
  --endpoint-url "$ENDPOINT" \
  --model "$MODEL" \
  --harness inference-perf \
  --workload tpm_coder_profile.yaml \
  --workload-file-path "$PROFILE_FILE" \
  --parallelism 1 \
  --data-access-timeout 600 \
  --overrides "vllmCommon.metricsPort=8000"

# --- 解析结果 ---
SLO=$TTFT_P99_SLO
python3 - "$WORKSPACE" "$SLO" "${CONCURRENCY_STEPS}" << 'PYEOF'
import json, glob, sys

workspace, slo_ms, conc_str = sys.argv[1], float(sys.argv[2]), sys.argv[3]
fallback_steps = conc_str.split(',')

result_dir = sorted(glob.glob(f'{workspace}/root-*/results/*_1'))
if not result_dir:
    print("未找到结果文件"); sys.exit(1)

result_dir = result_dir[0]
stages = sorted(glob.glob(f'{result_dir}/stage_*_lifecycle_metrics.json'))

# 从 workload yaml 读取真实 concurrency_level
steps = []
for wf in sorted(glob.glob(f'{result_dir}/*.yaml')):
    try:
        import yaml as _yaml
        with open(wf) as _f:
            wd = _yaml.safe_load(_f)
        load_val = wd.get("load")
        stgs = load_val if isinstance(load_val, list) else (load_val or {}).get("stages", []) if isinstance(load_val, dict) else []
        if stgs and isinstance(stgs[0], dict):
            if "concurrency_level" in stgs[0]:
                steps = [str(s["concurrency_level"]) + "c" for s in stgs]
                break
            elif "rate" in stgs[0]:
                steps = [str(s["rate"]) + " QPS" for s in stgs]
                break
    except: pass
if not steps:
    steps = fallback_steps

print()
print('='*90)
print('  TPM 测量结果 — Qwen Coder Trace（真实编码场景）')
print(f'  TTFT p99 SLO = {slo_ms:.0f}ms')
print('='*90)
print(f'  {"并发":>8} {"成功/失败":>10} {"output tok/s":>14} {"output TPM":>12} {"total TPM":>12} {"TTFT p50":>10} {"TTFT p99":>10} {"状态":>12}')
print(f'  {"-"*88}')

results = []
for i, sf in enumerate(stages):
    with open(sf) as f: d = json.load(f)
    s = d.get('successes', {}); fa = d.get('failures', {})
    tput = s.get('throughput', {}); lat = s.get('latency', {})
    ttft = lat.get('time_to_first_token', {})

    conc = steps[i] if i < len(steps) else '?'
    out_tps = tput.get('output_tokens_per_sec', 0)
    total_tps = tput.get('total_tokens_per_sec', 0)
    out_tpm = out_tps * 60
    total_tpm = total_tps * 60
    ttft_p50 = ttft.get('median', 0) * 1000
    ttft_p99 = ttft.get('p99', ttft.get('p99.0', 0)) * 1000

    ok = s.get('count', 0); fail = fa.get('count', 0)
    prev_tpm = results[-1]['out_tpm'] if results else 0
    saturated = prev_tpm > 0 and out_tpm < prev_tpm * 1.05
    slo_ok = ttft_p99 <= slo_ms or ttft_p99 == 0

    if fail > 0:
        status = 'ERRORS'
    elif not slo_ok:
        status = f'p99>{slo_ms:.0f}ms ✗'
    elif saturated:
        status = '饱和 ←'
    else:
        status = '正常'

    results.append(dict(conc=conc, out_tpm=out_tpm, total_tpm=total_tpm,
                        ttft_p50=ttft_p50, ttft_p99=ttft_p99, status=status,
                        slo_ok=slo_ok, ok=ok, fail=fail))
    print(f'  {conc:>8} {str(ok)+"/"+str(fail):>10} {out_tps:>14.0f} {out_tpm:>12.0f} {total_tpm:>12.0f} {ttft_p50:>10.0f} {ttft_p99:>10.0f} {status:>12}')

valid = [r for r in results if r['slo_ok'] and r['fail'] == 0]
if valid:
    best = max(valid, key=lambda r: r['out_tpm'])
    print()
    print(f'  ┌─ 结论 (TTFT p99 ≤ {slo_ms:.0f}ms 约束下) ────────────────────')
    print(f'  │  有效峰值 output TPM : {best["out_tpm"]:>10,.0f}  ({best["conc"]})')
    print(f'  │  有效峰值 total TPM  : {best["total_tpm"]:>10,.0f}  (input+output)')
    print(f'  │  对应 TTFT p50/p99   : {best["ttft_p50"]:.0f}ms / {best["ttft_p99"]:.0f}ms')
    print(f'  └──────────────────────────────────────────────────────────')
else:
    print()
    print(f'  所有并发数下 TTFT p99 均超过 SLO {slo_ms:.0f}ms，建议提高 --slo 或降低并发')

abs_best = max(results, key=lambda r: r['out_tpm'])
print(f'  绝对峰值 output TPM   : {abs_best["out_tpm"]:>10,.0f}  ({abs_best["conc"]}，不含 SLO 约束)')
PYEOF

echo ""
echo "  结果目录: $WORKSPACE"
