#!/usr/bin/env bash
# compare.sh — 对比两次基准测试结果
#
# 用法:
#   ./compare.sh <结果目录A> <结果目录B> [标签A] [标签B]
#
# 示例:
#   ./compare.sh results/llmd/inference-perf/20260713_203518 \
#                results/llmd/inference-perf/20260713_204742 \
#                "随机" "共享前缀"
#
# 结果目录可以是 timestamp 层目录，也可以直接是包含 stage_*.json 的目录

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 2 ]]; then
    echo "用法: $0 <结果目录A> <结果目录B> [标签A] [标签B]"
    echo ""
    echo "可用结果目录:"
    find "${SCRIPT_DIR}/results" -name "summary_lifecycle_metrics.json" 2>/dev/null \
        | sed "s|${SCRIPT_DIR}/||" | sed 's|/[^/]*/summary_lifecycle_metrics.json||' | sort -u
    exit 1
fi

DIR_A="$1"
DIR_B="$2"
LABEL_A="${3:-A}"
LABEL_B="${4:-B}"

# 在目录树中找 stage_*.json
find_stage_dir() {
    local base="$1"
    if ls "${base}"/stage_0_lifecycle_metrics.json &>/dev/null; then
        echo "$base"; return
    fi
    local found
    found=$(find "$base" -maxdepth 4 -name "stage_0_lifecycle_metrics.json" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        dirname "$found"; return
    fi
    # 尝试从 worker 节点找（hostPath PVC）
    local exp_id
    exp_id=$(basename "$(ls -td "${base}"/root-* 2>/dev/null | head -1)")
    if [[ -n "$exp_id" ]]; then
        local eid
        eid=$(grep -r "experiment=" "${base}/${exp_id}/run/" 2>/dev/null | grep -oP 'experiment=\K[^ ,]+' | head -1 || true)
        if [[ -n "$eid" ]]; then
            for node_ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
                local remote_dir="/mnt/llmdbench-workload-pvc/${eid}_1"
                if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 "root@${node_ip}" \
                    "ls ${remote_dir}/stage_0_lifecycle_metrics.json" &>/dev/null; then
                    echo "ssh:root@${node_ip}:${remote_dir}"; return
                fi
            done
        fi
    fi
    echo ""
}

STAGE_DIR_A=$(find_stage_dir "$DIR_A")
STAGE_DIR_B=$(find_stage_dir "$DIR_B")

if [[ -z "$STAGE_DIR_A" ]]; then
    echo "[ERROR] 找不到 $DIR_A 的 stage 结果文件" >&2; exit 1
fi
if [[ -z "$STAGE_DIR_B" ]]; then
    echo "[ERROR] 找不到 $DIR_B 的 stage 结果文件" >&2; exit 1
fi

python3 - "$STAGE_DIR_A" "$STAGE_DIR_B" "$LABEL_A" "$LABEL_B" "$DIR_A" "$DIR_B" << 'PYEOF'
import sys, json, subprocess, os, glob

def read_file(location, fname):
    if location.startswith("ssh:"):
        _, user_host, path = location.split(":", 2)
        r = subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", user_host,
                            f"cat {path}/{fname}"], capture_output=True, text=True)
        return r.stdout if r.stdout.strip() else ""
    fpath = os.path.join(location, fname)
    if not os.path.exists(fpath): return ""
    with open(fpath) as f: return f.read()

def read_json(location, fname):
    content = read_file(location, fname)
    try: return json.loads(content) if content else {}
    except: return {}

def read_yaml(location, fname):
    content = read_file(location, fname)
    if not content: return {}
    try:
        import yaml
        return yaml.safe_load(content) or {}
    except: return {}

def list_files(location, pattern):
    if location.startswith("ssh:"):
        _, user_host, path = location.split(":", 2)
        r = subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", user_host,
                            f"ls {path}/{pattern} 2>/dev/null"], capture_output=True, text=True)
        return [os.path.basename(f) for f in r.stdout.strip().split('\n') if f.strip()]
    return [os.path.basename(f) for f in glob.glob(os.path.join(location, pattern))]

def get_stages(location):
    stages = {}
    for i in range(8):
        d = read_json(location, f"stage_{i}_lifecycle_metrics.json")
        if d: stages[i] = d
        else: break
    return stages

def get_br_v02(location, stage):
    """读取 benchmark_report v0.2，提取 NTPOT 和 ITL"""
    files = list_files(location, f"benchmark_report_v0.2,_stage_{stage}_*.yaml")
    if not files: return {}
    d = read_yaml(location, files[0])
    try:
        return d.get('results', {}).get('request_performance', {}).get('aggregate', {}).get('latency', {})
    except: return {}

def get_observability(location, stage):
    """读取 benchmark_report v0.2 的 observability 字段（--monitoring 后才有）"""
    files = list_files(location, f"benchmark_report_v0.2,_stage_{stage}_*.yaml")
    if not files: return {}
    d = read_yaml(location, files[0])
    try:
        return d.get('results', {}).get('observability', {}) or {}
    except: return {}

loc_a, loc_b, label_a, label_b, dir_a, dir_b = sys.argv[1:]

stages_a = get_stages(loc_a)
stages_b = get_stages(loc_b)

if not stages_a:
    print(f"[ERROR] 找不到 {loc_a} 的结果", file=sys.stderr); sys.exit(1)
if not stages_b:
    print(f"[ERROR] 找不到 {loc_b} 的结果", file=sys.stderr); sys.exit(1)

def cjk_ljust(s, width):
    """处理中文字符双宽度的左对齐"""
    display_len = sum(2 if '一' <= c <= '鿿' or '　' <= c <= '〿' else 1 for c in s)
    pad = max(0, width - display_len)
    return s + ' ' * pad

def metric(d, *keys, default=0):
    v = d
    for k in keys:
        v = v.get(k, {}) if isinstance(v, dict) else {}
    return float(v) if isinstance(v, (int, float, str)) and str(v).replace('.','',1).lstrip('-').isdigit() else default

def cjk_rjust(s, width):
    """处理中文字符双宽度的右对齐"""
    display_len = sum(2 if '一' <= c <= '鿿' or '　' <= c <= '〿' else 1 for c in s)
    pad = max(0, width - display_len)
    return ' ' * pad + s

GREEN = chr(27) + '[32m'
RED   = chr(27) + '[31m'
RESET = chr(27) + '[0m'

def improve(a, b, lower_better=True):
    if a == 0: return "    -    "
    diff = (b - a) / a * 100
    pct = f"{abs(diff):.1f}%"
    if lower_better:
        if diff < 0:   return f"{GREEN}↓{pct}{RESET}".ljust(9 + len(GREEN) + len(RESET))
        elif diff > 0: return f"{RED}↑{pct}{RESET}".ljust(9 + len(GREEN) + len(RESET))
        else:          return "  0.0%   "
    else:
        if diff > 0:   return f"{GREEN}↑{pct}{RESET}".ljust(9 + len(GREEN) + len(RESET))
        elif diff < 0: return f"{RED}↓{pct}{RESET}".ljust(9 + len(GREEN) + len(RESET))
        else:          return "  0.0%   "

W = 18  # 指标名列宽（英文指标名最长约10字符，中文约14显示宽度）
SEP = "─" * (W + 42)
la_hdr = cjk_rjust(label_a, 12)
lb_hdr = cjk_rjust(label_b, 12)
print()
print(f"  {SEP}")
print(f"  {cjk_ljust('指标', W)}  {la_hdr}  {lb_hdr}  {'变化(绿↓/↑=改善)':>16}")
print(f"  {SEP}")

common_stages = sorted(set(stages_a) & set(stages_b))
rates = []
for i in common_stages:
    succ = metric(stages_a[i], 'successes', 'count')
    rate = round(succ / 120) if succ else i + 1
    rates.append(rate)

for idx, stage in enumerate(common_stages):
    da = stages_a[stage]
    db = stages_b[stage]
    sa = da.get('successes', {})
    sb = db.get('successes', {})
    fa = da.get('failures', {}).get('count', 0)
    fb = db.get('failures', {}).get('count', 0)

    # v0.2 report 补充指标
    bra = get_br_v02(loc_a, stage)
    brb = get_br_v02(loc_b, stage)
    obs_a = get_observability(loc_a, stage)
    obs_b = get_observability(loc_b, stage)

    rate = rates[idx]
    print(f"\n  ── rate={rate} QPS {'─'*50}")
    succ_a, succ_b = int(sa.get('count', 0)), int(sb.get('count', 0))
    fa_i, fb_i = int(fa), int(fb)
    sf_a = f"{succ_a}/{fa_i}"
    sf_b = f"{succ_b}/{fb_i}"
    print(f"  {cjk_ljust('成功/失败', W)}  {sf_a:>12}  {sf_b:>12}  {'':>16}")

    def row(name, *path, src_a=None, src_b=None, fmt=".3f", unit="s", lower_better=True, scale=1):
        sa_ = src_a if src_a is not None else sa
        sb_ = src_b if src_b is not None else sb
        va = metric(sa_, *path) * scale
        vb = metric(sb_, *path) * scale
        if va == 0 and vb == 0: return
        imp = improve(va, vb, lower_better)
        va_s = f"{va:{fmt}}{unit}"
        vb_s = f"{vb:{fmt}}{unit}"
        print(f"  {cjk_ljust(name, W)}  {va_s:>12}  {vb_s:>12}  {imp:>16}")

    # 核心延迟指标（从 stage_N json）
    row("TTFT p50",   'latency','time_to_first_token','median')
    row("TTFT p90",   'latency','time_to_first_token','p90')
    row("TTFT p99",   'latency','time_to_first_token','p99')
    row("TPOT p50",   'latency','time_per_output_token','median', scale=1000, fmt=".1f", unit="ms")
    row("ITL p50",    'latency','inter_token_latency','median',   scale=1000, fmt=".1f", unit="ms")
    row("E2E p50",    'latency','request_latency','median')
    row("E2E p90",    'latency','request_latency','p90')
    row("E2E p99",    'latency','request_latency','p99')

    ntpot_a = metric(bra, 'normalized_time_per_output_token', 'p50') * 1000
    ntpot_b = metric(brb, 'normalized_time_per_output_token', 'p50') * 1000
    if ntpot_a > 0 or ntpot_b > 0:
        imp = improve(ntpot_a, ntpot_b)
        na_s = f"{ntpot_a:.1f}ms"
        nb_s = f"{ntpot_b:.1f}ms"
        print(f"  {cjk_ljust('NTPOT p50', W)}  {na_s:>12}  {nb_s:>12}  {imp:>16}")

    # 吞吐量
    row("输出 tok/s",  'throughput','output_tokens_per_sec', fmt=".0f", unit=" ", lower_better=False)
    row("总 tok/s",   'throughput','total_tokens_per_sec',  fmt=".0f", unit=" ", lower_better=False)

    # 前缀缓存命中率（--monitoring 后才有）
    hit_a = metric(obs_a, 'vllm_prefix_cache_hit_rate', 'mean') * 100
    hit_b = metric(obs_b, 'vllm_prefix_cache_hit_rate', 'mean') * 100
    if hit_a > 0 or hit_b > 0:
        imp = improve(hit_a, hit_b, lower_better=False)
        print(f"  {cjk_ljust('KV cache 命中率', W)}  {hit_a:>11.1f}%   {hit_b:>11.1f}%   {imp:>16}")

    epp_a = metric(obs_a, 'inference_extension_prefix_indexer_hit_ratio', 'mean') * 100
    epp_b = metric(obs_b, 'inference_extension_prefix_indexer_hit_ratio', 'mean') * 100
    if epp_a > 0 or epp_b > 0:
        imp = improve(epp_a, epp_b, lower_better=False)
        print(f"  {cjk_ljust('EPP prefix 命中率', W)}  {epp_a:>11.1f}%   {epp_b:>11.1f}%   {imp:>16}")

print()
print(f"  {SEP}")
print(f"  注: {GREEN}绿色↓/↑{RESET} = 改善（延迟降低 或 吞吐提升）  {RED}红色{RESET} = 恶化")
print(f"  {label_a}: {dir_a}")
print(f"  {label_b}: {dir_b}")
print()
PYEOF
