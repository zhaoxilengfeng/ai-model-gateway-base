#!/usr/bin/env bash
# show.sh — 格式化展示一次测试的关键指标
#
# 用法:
#   ./show.sh                          # 展示最新一次结果
#   ./show.sh results/llmd/inference-perf/20260714_133941
#   ./show.sh <worker节点上的实验目录>   # 自动从 worker 节点读取

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 找结果目录 ---
TARGET="${1:-}"

find_latest() {
    # 先找本地
    local latest
    latest=$(find "${SCRIPT_DIR}/results" -name "summary_lifecycle_metrics.json" 2>/dev/null \
        | sort | tail -1)
    if [[ -n "$latest" ]]; then
        dirname "$latest"; return
    fi
    # 再找 worker 节点
    for node in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
        local exp
        exp=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 root@$node \
            "ls /mnt/llmdbench-workload-pvc/ | grep -v tokenizer | grep -v datasets | sort | tail -1" 2>/dev/null)
        if [[ -n "$exp" ]]; then
            echo "ssh:root@${node}:/mnt/llmdbench-workload-pvc/${exp}"
            return
        fi
    done
}

find_stage_dir() {
    local base="$1"
    if [[ "$base" == ssh:* ]]; then echo "$base"; return; fi
    if ls "${base}"/stage_0_lifecycle_metrics.json &>/dev/null; then echo "$base"; return; fi
    local found
    found=$(find "$base" -maxdepth 4 -name "stage_0_lifecycle_metrics.json" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then dirname "$found"; return; fi
    # 从 worker 节点找
    local exp_id
    exp_id=$(basename "$(ls -td "${base}"/root-* 2>/dev/null | head -1)" 2>/dev/null || true)
    if [[ -n "$exp_id" ]]; then
        local eid
        eid=$(grep -r "experiment=" "${base}/${exp_id}/run/" 2>/dev/null | grep -oP 'experiment=\K[^ ,]+' | head -1 || true)
        if [[ -n "$eid" ]]; then
            for node in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
                if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 "root@${node}" \
                    "ls /mnt/llmdbench-workload-pvc/${eid}_1/stage_0_lifecycle_metrics.json" &>/dev/null; then
                    echo "ssh:root@${node}:/mnt/llmdbench-workload-pvc/${eid}_1"; return
                fi
            done
        fi
    fi
    echo ""
}

if [[ -z "$TARGET" ]]; then
    TARGET=$(find_latest)
fi

if [[ -z "$TARGET" ]]; then
    echo "[ERROR] 找不到任何测试结果" >&2; exit 1
fi

STAGE_DIR=$(find_stage_dir "$TARGET")
if [[ -z "$STAGE_DIR" ]]; then
    echo "[ERROR] 找不到 stage 结果文件: $TARGET" >&2; exit 1
fi

python3 - "$STAGE_DIR" "$TARGET" << 'PYEOF'
import sys, json, subprocess, os, glob

def read_file(location, fname):
    if location.startswith("ssh:"):
        _, user_host, path = location.split(":", 2)
        r = subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", user_host,
                            f"cat {path}/{fname}"], capture_output=True, text=True)
        return r.stdout if r.stdout.strip() else ""
    fpath = os.path.join(location, fname)
    return open(fpath).read() if os.path.exists(fpath) else ""

def read_json(location, fname):
    c = read_file(location, fname)
    try: return json.loads(c) if c else {}
    except: return {}

def list_files(location, pattern):
    if location.startswith("ssh:"):
        _, user_host, path = location.split(":", 2)
        r = subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", user_host,
                            f"ls {path}/{pattern} 2>/dev/null"], capture_output=True, text=True)
        return [os.path.basename(f) for f in r.stdout.strip().splitlines() if f.strip()]
    return [os.path.basename(f) for f in glob.glob(os.path.join(location, pattern))]

def m(d, *keys, default=0):
    v = d
    for k in keys:
        v = v.get(k, {}) if isinstance(v, dict) else {}
    try: return float(v)
    except: return default

def bar(val, max_val, width=20, char="█"):
    if max_val == 0: return " " * width
    filled = int(val / max_val * width)
    return char * filled + "░" * (width - filled)

def fmt_ms(s): return f"{s*1000:.1f}ms"
def fmt_s(s):  return f"{s:.3f}s"

loc, target = sys.argv[1], sys.argv[2]

# 读取所有 stage
stages = {}
for i in range(8):
    d = read_json(loc, f"stage_{i}_lifecycle_metrics.json")
    if d: stages[i] = d
    else: break

if not stages:
    print("[ERROR] 没有找到结果数据"); sys.exit(1)

# 读取 run_metadata
meta = read_json(loc, "run_metadata.json") or {}

# 推断各 stage 的 rate（从 run_metadata 里的 workload 配置读，fallback 到 succ/duration）
rates = {}
# 先尝试从 workload yaml 文件读 stage 配置
workload_files = list_files(loc, "*.yaml") + list_files(loc, "*.yaml.in")
stage_durations = {}
for wf in workload_files:
    content = read_file(loc, wf)
    if 'stages' in content and 'rate' in content:
        try:
            import yaml as _yaml
            wdata = _yaml.safe_load(content)
            stgs = (wdata.get('load') or {}).get('stages', [])
            for si, st in enumerate(stgs):
                if isinstance(st, dict):
                    stage_durations[si] = st.get('duration', 120)
        except: pass
        break

for i, d in stages.items():
    succ = m(d, 'successes', 'count')
    dur = stage_durations.get(i, 120)
    rates[i] = round(succ / dur) if succ and dur else i+1

print()
print("╔══════════════════════════════════════════════════════╗")
print("║              基准测试结果报告                        ║")
print("╚══════════════════════════════════════════════════════╝")
print(f"  结果路径: {target}")
print()

# === 汇总 ===
summary = read_json(loc, "summary_lifecycle_metrics.json")
if summary:
    total = m(summary, 'load_summary', 'count')
    succ  = m(summary, 'successes', 'count')
    fail  = m(summary, 'failures', 'count')
    out_tps = m(summary, 'successes', 'throughput', 'output_tokens_per_sec')
    ttft_p50 = m(summary, 'successes', 'latency', 'time_to_first_token', 'median')
    ttft_p99 = m(summary, 'successes', 'latency', 'time_to_first_token', 'p99')
    e2e_p50  = m(summary, 'successes', 'latency', 'request_latency', 'median')

    sr = succ / total * 100 if total else 0
    print(f"  ┌─ 总体概览 ─────────────────────────────┐")
    print(f"  │  总请求数   : {int(total):>6}                     │")
    print(f"  │  成功       : {int(succ):>6}  ({sr:.1f}%)             │")
    print(f"  │  失败       : {int(fail):>6}                     │")
    print(f"  │  输出吞吐   : {out_tps:>6.0f} tokens/s          │")
    print(f"  │  TTFT p50   : {fmt_ms(ttft_p50):>8}                 │")
    print(f"  │  TTFT p99   : {fmt_ms(ttft_p99):>8}                 │")
    print(f"  │  E2E   p50  : {fmt_s(e2e_p50):>8}                 │")
    print(f"  └───────────────────────────────────────┘")
    print()

# === 各 Stage 详情 ===
print("  ┌─ 各并发阶段详情 ──────────────────────────────────────────────────────┐")
print(f"  │  {'Stage':<6} {'QPS':>4}  {'成功/失败':>10}  {'TTFT p50':>9}  {'TTFT p99':>9}  {'TPOT p50':>9}  {'E2E p50':>8}  {'tok/s':>7}  │")
print(f"  │  {'─'*6} {'─'*4}  {'─'*10}  {'─'*9}  {'─'*9}  {'─'*9}  {'─'*8}  {'─'*7}  │")

max_tps = max((m(d, 'successes', 'throughput', 'output_tokens_per_sec') for d in stages.values()), default=1)

for i, d in sorted(stages.items()):
    sa = d.get('successes', {})
    fa = d.get('failures', {}).get('count', 0)
    succ = int(m(sa, 'count'))
    rate = rates[i]
    ttft50 = fmt_ms(m(sa, 'latency', 'time_to_first_token', 'median'))
    ttft99 = fmt_ms(m(sa, 'latency', 'time_to_first_token', 'p99'))
    tpot50 = fmt_ms(m(sa, 'latency', 'time_per_output_token', 'median'))
    e2e50  = fmt_s(m(sa, 'latency', 'request_latency', 'median'))
    tps    = m(sa, 'throughput', 'output_tokens_per_sec')
    sf = f"{succ}/{int(fa)}"
    print(f"  │  {i:<6} {rate:>4}  {sf:>10}  {ttft50:>9}  {ttft99:>9}  {tpot50:>9}  {e2e50:>8}  {tps:>7.0f}  │")

print(f"  └───────────────────────────────────────────────────────────────────────┘")
print()

# === TTFT 趋势图（ASCII）===
print("  ┌─ TTFT p50 随负载变化趋势 ─────────────────────────────┐")
ttft_vals = [m(stages[i], 'successes', 'latency', 'time_to_first_token', 'median') for i in sorted(stages)]
max_ttft = max(ttft_vals) if ttft_vals else 1
for i, (stage, ttft) in enumerate(zip(sorted(stages), ttft_vals)):
    rate = rates[stage]
    b = bar(ttft, max_ttft, width=30)
    print(f"  │  {rate:>2} QPS  {b}  {fmt_ms(ttft):>8}  │")
print(f"  └──────────────────────────────────────────────────────┘")
print()

# === 吞吐趋势图 ===
print("  ┌─ 输出吞吐 (tokens/s) 随负载变化 ─────────────────────┐")
tps_vals = [m(stages[i], 'successes', 'throughput', 'output_tokens_per_sec') for i in sorted(stages)]
max_tps = max(tps_vals) if tps_vals else 1
for i, (stage, tps) in enumerate(zip(sorted(stages), tps_vals)):
    rate = rates[stage]
    b = bar(tps, max_tps, width=30, char="▓")
    print(f"  │  {rate:>2} QPS  {b}  {tps:>7.0f}  │")
print(f"  └──────────────────────────────────────────────────────┘")
print()

PYEOF
