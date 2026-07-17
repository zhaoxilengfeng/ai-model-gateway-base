#!/usr/bin/env bash
# report.sh — 从测试结果自动生成 Markdown 报告并保存到 reports/
#
# 用法：
#   bash report.sh                            # 对最新一次测试生成报告
#   bash report.sh results/llmd/.../20260717  # 指定结果目录
#   bash report.sh --name "shared-prefix-vs-random"  # 自定义报告文件名
#   bash report.sh --title "共享前缀 vs 随机路由对比"  # 自定义标题
#
# 报告保存到：reports/YYYY-MM-DD-<name>.md

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="${SCRIPT_DIR}/reports"
mkdir -p "$REPORTS_DIR"

TARGET=""
REPORT_NAME=""
REPORT_TITLE=""
GATEWAY="llmd"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   REPORT_NAME="$2";  shift 2 ;;
    --title)  REPORT_TITLE="$2"; shift 2 ;;
    --gateway) GATEWAY="$2";     shift 2 ;;
    -*) shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

# 找最新结果目录
if [[ -z "$TARGET" ]]; then
  TARGET=$(find "${SCRIPT_DIR}/results" -name "summary_lifecycle_metrics.json" 2>/dev/null \
    | sort | tail -1 | xargs -I{} dirname {} 2>/dev/null || true)
  if [[ -z "$TARGET" ]]; then
    echo "[ERROR] 未找到测试结果，请先运行测试或指定结果目录" >&2
    exit 1
  fi
fi

# 找 stage 目录
find_stage_dir() {
  local base="$1"
  if ls "${base}"/stage_0_lifecycle_metrics.json &>/dev/null; then
    echo "$base"; return
  fi
  local found
  found=$(find "$base" -maxdepth 5 -name "stage_0_lifecycle_metrics.json" 2>/dev/null | head -1)
  [[ -n "$found" ]] && dirname "$found" || echo ""
}

STAGE_DIR=$(find_stage_dir "$TARGET")
if [[ -z "$STAGE_DIR" ]]; then
  echo "[ERROR] 找不到 stage 结果文件: $TARGET" >&2
  exit 1
fi

# 生成报告
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)

python3 - "$STAGE_DIR" "$TARGET" "$REPORT_NAME" "$REPORT_TITLE" "$GATEWAY" "$REPORTS_DIR" "$DATE" "$TIMESTAMP" << 'PYEOF'
import sys, json, os, glob, subprocess
import yaml as _yaml

stage_dir, target, rname, rtitle, gateway, reports_dir, date, ts = sys.argv[1:]

def read_json(path, fname):
    fpath = os.path.join(path, fname)
    try:
        with open(fpath) as f: return json.load(f)
    except: return {}

def m(d, *keys, default=0):
    v = d
    for k in keys:
        v = v.get(k, {}) if isinstance(v, dict) else {}
    try: return float(v)
    except: return default

# 读取所有 stage
stages = {}
for i in range(8):
    d = read_json(stage_dir, f"stage_{i}_lifecycle_metrics.json")
    if d: stages[i] = d
    else: break

summary = read_json(stage_dir, "summary_lifecycle_metrics.json")
meta = read_json(stage_dir, "run_metadata.yaml") or {}

# 从 workload yaml 读取 stage 标签
stage_labels = {}
d = stage_dir
for _ in range(6):
    for wf in sorted(glob.glob(os.path.join(d, "*.yaml"))):
        try:
            with open(wf) as f:
                wd = _yaml.safe_load(f)
            if not isinstance(wd, dict): continue
            load_val = wd.get("load")
            stgs = load_val if isinstance(load_val, list) else (load_val or {}).get("stages", []) if isinstance(load_val, dict) else []
            for si, st in enumerate(stgs):
                if not isinstance(st, dict): continue
                if "concurrency_level" in st:
                    stage_labels[si] = str(st["concurrency_level"]) + "c"
                elif "rate" in st:
                    stage_labels[si] = str(st["rate"]) + " QPS"
            if stage_labels: break
        except: pass
    if stage_labels: break
    parent = os.path.dirname(d)
    if parent == d: break
    d = parent

for i, d in stages.items():
    if i not in stage_labels:
        bt = m(d, "benchmark_time_seconds")
        succ = m(d, "successes", "count")
        stage_labels[i] = f"{round(succ/bt)} QPS" if (bt > 0 and succ > 0) else f"stage{i}"

# 推断报告名称和标题
if not rname:
    # 从目录路径提取信息
    parts = target.rstrip("/").split("/")
    for p in reversed(parts):
        if p.startswith("20") and len(p) >= 8:
            rname = p
            break
    if not rname:
        rname = ts.replace(":", "").replace(" ", "_")

if not rtitle:
    # 从 workload 文件名推断
    workload_files = glob.glob(os.path.join(stage_dir, "*override*.yaml")) + \
                     glob.glob(os.path.join(stage_dir, "*.yaml"))
    wname = ""
    for wf in workload_files:
        bn = os.path.basename(wf)
        if "sweep" in bn or "coder" in bn or "tpm" in bn or "sanity" in bn:
            wname = bn.replace(".yaml", "").replace("-override", "").replace("_", " ")
            break
    rtitle = f"基准测试报告 — {wname or os.path.basename(stage_dir)}"

report_path = os.path.join(reports_dir, f"{rname if rname.startswith(date[:7]) else date + "-" + rname}.md")

# 生成 Markdown
lines = []
lines.append(f"# {rtitle}")
lines.append("")
lines.append(f"**日期**: {date}  ")
lines.append(f"**网关**: {gateway}  ")
lines.append(f"**结果目录**: `{target}`  ")
lines.append("")

# 总体概览
if summary:
    total = m(summary, "load_summary", "count")
    succ  = m(summary, "successes", "count")
    fail  = m(summary, "failures", "count")
    out_tps = m(summary, "successes", "throughput", "output_tokens_per_sec")
    ttft_p50 = m(summary, "successes", "latency", "time_to_first_token", "median") * 1000
    ttft_p99 = m(summary, "successes", "latency", "time_to_first_token", "p99") * 1000
    e2e_p50  = m(summary, "successes", "latency", "request_latency", "median")

    lines.append("## 总体概览")
    lines.append("")
    lines.append("| 指标 | 数值 |")
    lines.append("|------|------|")
    lines.append(f"| 总请求数 | {int(total):,} |")
    lines.append(f"| 成功 / 失败 | {int(succ):,} / {int(fail):,} ({succ/total*100:.1f}%) |")
    lines.append(f"| 输出吞吐 | {out_tps:,.0f} tokens/s |")
    lines.append(f"| TTFT p50 | {ttft_p50:.0f}ms |")
    lines.append(f"| TTFT p99 | {ttft_p99:.0f}ms |")
    lines.append(f"| E2E p50 | {e2e_p50:.3f}s |")
    lines.append("")

# 各阶段详情
lines.append("## 各阶段详情")
lines.append("")
lines.append("| 阶段 | 成功/失败 | output tok/s | TTFT p50 | TTFT p90 | TTFT p99 | TPOT p50 | E2E p50 |")
lines.append("|------|-----------|-------------|---------|---------|---------|---------|---------|")

for i, d in sorted(stages.items()):
    sa = d.get("successes", {})
    fa = d.get("failures", {}).get("count", 0)
    lat = sa.get("latency", {})
    tput = sa.get("throughput", {})
    ttft = lat.get("time_to_first_token", {})
    tpot = lat.get("time_per_output_token", {})
    e2e  = lat.get("request_latency", {})

    label = stage_labels.get(i, f"stage{i}")
    ok = int(sa.get("count", 0))
    out_tps = tput.get("output_tokens_per_sec", 0)
    lines.append(
        f"| {label} | {ok}/{int(fa)} "
        f"| {out_tps:,.0f} "
        f"| {ttft.get('median',0)*1000:.0f}ms "
        f"| {ttft.get('p90',0)*1000:.0f}ms "
        f"| {ttft.get('p99',0)*1000:.0f}ms "
        f"| {tpot.get('median',0)*1000:.1f}ms "
        f"| {e2e.get('median',0):.3f}s |"
    )

lines.append("")

# Token 分布（如果有）
if summary:
    sa = summary.get("successes", {})
    ol = sa.get("output_len", {})
    il = sa.get("prompt_len", {})
    if ol or il:
        lines.append("## Token 分布")
        lines.append("")
        lines.append("| 指标 | 均值 | p50 | p90 |")
        lines.append("|------|------|-----|-----|")
        if il:
            lines.append(f"| Input token | {il.get('mean',0):.0f} | {il.get('median',0):.0f} | {il.get('p90',0):.0f} |")
        if ol:
            lines.append(f"| Output token | {ol.get('mean',0):.0f} | {ol.get('median',0):.0f} | {ol.get('p90',0):.0f} |")
        lines.append("")

# KV cache 命中率（从 vLLM pod metrics 获取，若有）
pt = sa.get("prompt_tokens", {}) if summary else {}
if pt and pt.get("total", 0) > 0:
    hit = pt.get("cached", 0) / pt.get("total", 1) * 100
    lines.append(f"**KV cache 命中率**: {hit:.1f}%  ")
    lines.append("")

# 复现命令
lines.append("## 复现命令")
lines.append("")
lines.append("```bash")
lines.append("cd /root/ai-model-gateway-base/gateway-benchmark")
# 尝试从 workload yaml 推断命令
wl_name = ""
for wf in glob.glob(os.path.join(stage_dir, "*override*.yaml")):
    bn = os.path.basename(wf).replace("-override.yaml", "").replace("_override.yaml", "")
    if bn and bn != "config":
        wl_name = bn
        break
if wl_name:
    lines.append(f"bash run_{gateway}.sh --workload {wl_name}.yaml")
else:
    lines.append(f"# 参考结果目录: {target}")
lines.append("```")
lines.append("")

# 写入文件
with open(report_path, "w") as f:
    f.write("\n".join(lines))

print(f"报告已生成: {report_path}")
PYEOF
