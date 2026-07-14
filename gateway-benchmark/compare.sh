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
    # 先找是否直接包含 stage_0_lifecycle_metrics.json
    if ls "${base}"/stage_0_lifecycle_metrics.json &>/dev/null; then
        echo "$base"
        return
    fi
    # 往下找一层
    local found
    found=$(find "$base" -maxdepth 4 -name "stage_0_lifecycle_metrics.json" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        dirname "$found"
        return
    fi
    # 尝试从 worker 节点找（hostPath PVC）
    local exp_id
    exp_id=$(basename "$(ls -td "${base}"/root-* 2>/dev/null | head -1)")
    if [[ -n "$exp_id" ]]; then
        # 从 stdout 日志里找 experiment id
        local eid
        eid=$(grep -r "experiment=" "${base}/${exp_id}/run/" 2>/dev/null | grep -oP 'experiment=\K[^ ,]+' | head -1 || true)
        if [[ -n "$eid" ]]; then
            for node_ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
                local remote_dir="/mnt/llmdbench-workload-pvc/${eid}_1"
                if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 "root@${node_ip}" \
                    "ls ${remote_dir}/stage_0_lifecycle_metrics.json" &>/dev/null; then
                    echo "ssh:root@${node_ip}:${remote_dir}"
                    return
                fi
            done
        fi
    fi
    echo ""
}

read_json() {
    local location="$1"
    local file="$2"
    if [[ "$location" == ssh:* ]]; then
        local user_host="${location#ssh:}"
        local host="${user_host%%:*}"
        local path="${user_host#*:}"
        ssh -o StrictHostKeyChecking=no "$host" "cat ${path}/${file}" 2>/dev/null
    else
        cat "${location}/${file}" 2>/dev/null
    fi
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
import sys, json, subprocess, os

def read_json(location, fname):
    if location.startswith("ssh:"):
        _, user_host, path = location.split(":", 2)
        r = subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", user_host,
                            f"cat {path}/{fname}"], capture_output=True, text=True)
        return json.loads(r.stdout) if r.stdout.strip() else {}
    fpath = os.path.join(location, fname)
    if not os.path.exists(fpath):
        return {}
    with open(fpath) as f:
        return json.load(f)

def get_stages(location):
    stages = {}
    for i in range(8):
        d = read_json(location, f"stage_{i}_lifecycle_metrics.json")
        if d:
            stages[i] = d
        else:
            break
    return stages

loc_a, loc_b, label_a, label_b, dir_a, dir_b = sys.argv[1:]

stages_a = get_stages(loc_a)
stages_b = get_stages(loc_b)

if not stages_a:
    print(f"[ERROR] 找不到 {loc_a} 的结果", file=sys.stderr); sys.exit(1)
if not stages_b:
    print(f"[ERROR] 找不到 {loc_b} 的结果", file=sys.stderr); sys.exit(1)

def metric(d, *keys, default=0):
    v = d
    for k in keys:
        v = v.get(k, {}) if isinstance(v, dict) else {}
    return v if isinstance(v, (int, float)) else default

def improve(a, b, lower_better=True):
    if a == 0: return "-"
    diff = (a - b) / a * 100 if lower_better else (b - a) / a * 100
    arrow = "↓" if diff > 0 else "↑"
    return f"{arrow}{abs(diff):.1f}%"

W = 26
print()
print(f"  {'':=<{W+30}}")
print(f"  {'指标':<{W}} {label_a:>10}  {label_b:>10}  {'变化':>8}")
print(f"  {'':=<{W+30}}")

common_stages = sorted(set(stages_a) & set(stages_b))
rates = []
for i in common_stages:
    # 推断 rate: 成功数 / 120s
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

    rate = rates[idx]
    print(f"\n  --- rate={rate} QPS ---")

    succ_a, succ_b = sa.get('count', 0), sb.get('count', 0)
    print(f"  {'成功/失败':<{W}} {succ_a:>4}/{fa:<5} {succ_b:>4}/{fb:<5}")

    def row(name, *path, fmt=".2f", unit="s", lower_better=True, scale=1):
        va = metric(sa, *path) * scale
        vb = metric(sb, *path) * scale
        if va == 0 and vb == 0: return
        imp = improve(va, vb, lower_better)
        print(f"  {name:<{W}} {va:>9{fmt}}{unit}  {vb:>9{fmt}}{unit}  {imp:>8}")

    row("TTFT p50",   'latency','time_to_first_token','median')
    row("TTFT p90",   'latency','time_to_first_token','p90')
    row("TTFT p99",   'latency','time_to_first_token','p99')
    row("TPOT p50",   'latency','time_per_output_token','median', scale=1000, fmt=".1f", unit="ms")
    row("E2E p50",    'latency','request_latency','median')
    row("E2E p90",    'latency','request_latency','p90')
    row("输出 tok/s", 'throughput','output_tokens_per_sec', fmt=".1f", unit=" ", lower_better=False)
    row("总 tok/s",   'throughput','total_tokens_per_sec',  fmt=".1f", unit=" ", lower_better=False)

print()
print(f"  {'':=<{W+30}}")
print(f"  {label_a}: {dir_a}")
print(f"  {label_b}: {dir_b}")
print()
PYEOF
