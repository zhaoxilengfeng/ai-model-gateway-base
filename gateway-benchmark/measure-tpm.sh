#!/usr/bin/env bash
# measure-tpm.sh v2 — 测量 llm-d 集群 TPM 上限
#
# 方法：
#   1. 用 concurrent 模式逐步提升并发数（模拟用户数增加）
#   2. 找到吞吐量饱和点（增量 < 5%）和延迟拐点
#   3. 报告"在 TTFT p99 ≤ SLO 约束下的最大可持续 TPM"
#
# 与 vLLM benchmark_serving.py 的关系：
#   - 本脚本用 llmdbenchmark concurrent 模式，等价于 --request-rate inf
#   - 每阶段至少跑 duration_seconds，保证统计稳定
#
# 用法：
#   bash measure-tpm.sh                          # 默认参数
#   bash measure-tpm.sh --concurrency 8,16,32,64,128  # 自定义并发阶梯
#   bash measure-tpm.sh --slo 500                # TTFT p99 SLO (ms)，默认 1000ms
#   bash measure-tpm.sh --output-mean 512        # 输出 token 均值，默认 256
#   bash measure-tpm.sh --dry-run

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"

# --- 默认参数 ---
# 并发阶梯：从 GPU 数（8）开始，逐步 2× 直到饱和
CONCURRENCY_STEPS="${CONCURRENCY:-8,16,32,64,128}"
# 每阶段请求数：足够多保证统计稳定（并发 128 时约跑 120s）
REQUESTS_PER_STEP="${REQUESTS:-400}"
INPUT_MEAN="${INPUT_MEAN:-512}"
INPUT_MAX="${INPUT_MAX:-1024}"
OUTPUT_MEAN="${OUTPUT_MEAN:-256}"
OUTPUT_MAX="${OUTPUT_MAX:-512}"
# TTFT p99 SLO（毫秒）：超过此值视为"延迟不可接受"
TTFT_P99_SLO="${SLO:-1000}"
# 数据类型：random（随机输入）| shared_prefix（共享前缀，测 KV cache 收益）
DATA_TYPE="${DATA_TYPE:-random}"
# shared_prefix 场景参数
SP_NUM_GROUPS="${SP_NUM_GROUPS:-32}"
SP_PROMPTS_PER_GROUP="${SP_PROMPTS_PER_GROUP:-32}"
SP_SYSTEM_LEN="${SP_SYSTEM_LEN:-512}"
DRY_RUN=false
GATEWAY="${GATEWAY:-llmd}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency)  CONCURRENCY_STEPS="$2"; shift 2 ;;
    --requests)     REQUESTS_PER_STEP="$2"; shift 2 ;;
    --input-mean)   INPUT_MEAN="$2"; shift 2 ;;
    --output-mean)  OUTPUT_MEAN="$2"; shift 2 ;;
    --slo)          TTFT_P99_SLO="$2"; shift 2 ;;
    --data-type)    DATA_TYPE="$2"; shift 2 ;;
    --sp-groups)    SP_NUM_GROUPS="$2"; shift 2 ;;
    --sp-system-len) SP_SYSTEM_LEN="$2"; shift 2 ;;
    --gateway)      GATEWAY="$2"; shift 2 ;;
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

ENDPOINT=$(yaml_get ".${GATEWAY}.endpoint_url")
MODEL=$(yaml_get ".${GATEWAY}.model")
NAMESPACE=$(yaml_get ".${GATEWAY}.namespace")

echo "=============================================="
echo "  TPM 上限测量 v2"
echo "  Endpoint:    $ENDPOINT"
echo "  Model:       $MODEL"
echo "  并发阶梯:    $CONCURRENCY_STEPS"
echo "  每阶段请求:  $REQUESTS_PER_STEP"
echo "  Input mean:  $INPUT_MEAN tokens"
echo "  Output mean: $OUTPUT_MEAN tokens"
echo "  Data type:   $DATA_TYPE"
[[ "$DATA_TYPE" == "shared_prefix" ]] && echo "  SP config:   ${SP_NUM_GROUPS}g x ${SP_PROMPTS_PER_GROUP}p, system=${SP_SYSTEM_LEN}tok, question=${INPUT_MEAN}tok, output=${OUTPUT_MEAN}tok"
echo "  Gateway:      $GATEWAY"
echo "  TTFT p99 SLO: ${TTFT_P99_SLO}ms"
echo "=============================================="

source /root/llm-d-benchmark/.venv/bin/activate

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
WORKSPACE="${SCRIPT_DIR}/results/${GATEWAY}/inference-perf/tpm_${TIMESTAMP}"
mkdir -p "$WORKSPACE"
PROFILE_FILE="${WORKSPACE}/tpm_profile.yaml.in"

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
  type: completion
  streaming: true
server:
  type: vllm
  model_name: REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL
  base_url: REPLACE_ENV_LLMDBENCH_HARNESS_STACK_ENDPOINT_URL
  ignore_eos: true
tokenizer:
  pretrained_model_name_or_path: /requests/tokenizer
$(if [[ "$DATA_TYPE" == "shared_prefix" ]]; then
printf "data:\n  type: shared_prefix\n  shared_prefix:\n    num_groups: ${SP_NUM_GROUPS}\n    num_prompts_per_group: ${SP_PROMPTS_PER_GROUP}\n    system_prompt_len: ${SP_SYSTEM_LEN}\n    question_len: ${INPUT_MEAN}\n    output_len: ${OUTPUT_MEAN}"
else
printf "data:\n  type: random\n  input_distribution:\n    min: 128\n    max: ${INPUT_MAX}\n    mean: ${INPUT_MEAN}\n    std: 256\n  output_distribution:\n    min: 64\n    max: ${OUTPUT_MAX}\n    mean: ${OUTPUT_MEAN}\n    std: 64"
fi)
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
  --workload tpm_profile.yaml \
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

# 从 workload yaml 读取真实 concurrency_level 或 rate
steps = []
for wf in sorted(glob.glob(f'{result_dir}/*.yaml')):
    try:
        import yaml as _yaml
        with open(wf) as _f:
            wd = _yaml.safe_load(_f)
        stgs = (wd.get("load") or {}).get("stages", [])
        if stgs and isinstance(stgs[0], dict):
            if "concurrency_level" in stgs[0]:
                steps = [str(s["concurrency_level"])+"c" for s in stgs]
                break
            elif "rate" in stgs[0]:
                steps = [str(s["rate"])+" QPS" for s in stgs]
                break
    except: pass
if not steps:
    steps = fallback_steps

print()
print('='*90)
print('  TPM 测量结果')
print(f'  TTFT p99 SLO = {slo_ms:.0f}ms  (超过此值视为延迟不可接受)')
print('='*90)
print(f'  {"并发/QPS":>8} {"成功/失败":>10} {"output tok/s":>14} {"output TPM":>12} {"total TPM":>12} {"TTFT p50":>10} {"TTFT p99":>10} {"状态":>12}')
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
    # p99 字段名
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

# 有效 TPM = SLO 内的最高 output TPM
valid = [r for r in results if r['slo_ok'] and r['fail'] == 0]
if valid:
    best = max(valid, key=lambda r: r['out_tpm'])
    print()
    print(f'  ┌─ 结论 (TTFT p99 ≤ {slo_ms:.0f}ms 约束下) ────────────────────')
    print(f'  │  有效峰值 output TPM : {best["out_tpm"]:>10,.0f}  (并发={best["conc"]})')
    print(f'  │  有效峰值 total TPM  : {best["total_tpm"]:>10,.0f}  (input+output)')
    print(f'  │  对应 TTFT p50/p99   : {best["ttft_p50"]:.0f}ms / {best["ttft_p99"]:.0f}ms')
    print(f'  └──────────────────────────────────────────────────────────')
else:
    print()
    print(f'  所有并发数下 TTFT p99 均超过 SLO {slo_ms:.0f}ms，需降低 SLO 或减小并发')

abs_best = max(results, key=lambda r: r['out_tpm'])
print(f'  绝对峰值 output TPM   : {abs_best["out_tpm"]:>10,.0f}  (并发={abs_best["conc"]}，不含 SLO 约束)')
PYEOF

echo ""
echo "  结果目录: $WORKSPACE"
