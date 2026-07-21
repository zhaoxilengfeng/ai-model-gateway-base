#!/usr/bin/env bash
# run_multimodel.sh — 多模型并发基准测试
#
# 验证内容：
#   1. 路由正确性：响应 model 字段与请求一致（不跨池路由）
#   2. 单模型基线：无竞争时各模型的 TTFT/吞吐
#   3. 多模型并发：同时压测两模型，观察资源竞争影响
#
# 用法：
#   bash run_multimodel.sh
#   bash run_multimodel.sh --concurrency 20 --requests 50

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENDPOINT="${ENDPOINT:-http://116.198.67.18:31273}"
CONCURRENCY="${CONCURRENCY:-10}"
REQUESTS="${REQUESTS:-30}"
MAX_TOKENS="${MAX_TOKENS:-30}"
MODELS=("qwen25-7b-instruct" "glm-4-9b")

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)    ENDPOINT="$2";    shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --requests)    REQUESTS="$2";    shift 2 ;;
    --max-tokens)  MAX_TOKENS="$2";  shift 2 ;;
    *) shift ;;
  esac
done

TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

# 写 Python 压测脚本到临时文件
cat > "$TMPDIR_BENCH/bench.py" << 'PYEOF'
import sys, json, time, threading, urllib.request

endpoint = sys.argv[1]
model    = sys.argv[2]
conc     = int(sys.argv[3])
n_req    = int(sys.argv[4])
max_tok  = int(sys.argv[5])
outfile  = sys.argv[6]

results = []
lock = threading.Lock()

def send():
    start = time.time()
    try:
        req = urllib.request.Request(
            f"{endpoint}/v1/chat/completions",
            data=json.dumps({"model": model,
                "messages": [{"role": "user", "content": "hello"}],
                "max_tokens": max_tok, "stream": False}).encode(),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read())
        elapsed = time.time() - start
        tokens = d.get("usage", {}).get("total_tokens", 0)
        resp_model = d.get("model", "?")
        with lock:
            results.append({"ttft": elapsed, "tokens": tokens,
                            "ok": True, "routing_ok": resp_model == model})
    except Exception:
        with lock:
            results.append({"ttft": 0, "tokens": 0, "ok": False, "routing_ok": False})

active = []
for _ in range(n_req):
    t = threading.Thread(target=send)
    t.start()
    active.append(t)
    if len(active) >= conc:
        for th in active: th.join()
        active = []
for t in active: t.join()

ok_r = [r for r in results if r["ok"]]
if ok_r:
    ttfts = sorted(r["ttft"] for r in ok_r)
    total_tok = sum(r["tokens"] for r in ok_r)
    elapsed_max = max(r["ttft"] for r in ok_r)
    tps = total_tok / max(elapsed_max, 0.001)
    p50 = ttfts[len(ttfts)//2]
    p90 = ttfts[int(len(ttfts)*0.9)]
    routing_ok = sum(1 for r in ok_r if r["routing_ok"])
    with open(outfile, "w") as f:
        f.write(f"{len(ok_r)} {len(results)} {p50*1000:.0f} {p90*1000:.0f} {tps:.0f} {routing_ok}\n")
else:
    with open(outfile, "w") as f:
        f.write(f"0 {len(results)} 0 0 0 0\n")
PYEOF

echo "================================================================"
echo "  多模型并发基准测试"
echo "  入口:       $ENDPOINT"
echo "  模型:       ${MODELS[*]}"
echo "  并发/模型:  $CONCURRENCY"
echo "  请求/模型:  $REQUESTS"
echo "================================================================"

# ── 阶段一：路由正确性 ─────────────────────────────────────────────
echo ""
echo "▶ 阶段一：路由正确性（各发 5 次请求，验证响应 model 字段）"

ROUTE_PASS=0; ROUTE_FAIL=0
for MODEL in "${MODELS[@]}"; do
  for i in $(seq 1 5); do
    RESP=$(curl -s --max-time 20 "$ENDPOINT/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" 2>/dev/null)
    RESP_MODEL=$(echo "$RESP" | python3 -c \
      'import sys,json; print(json.load(sys.stdin).get("model","?"))' 2>/dev/null)
    if [[ "$RESP_MODEL" == "$MODEL" ]]; then
      ROUTE_PASS=$((ROUTE_PASS+1))
    else
      ROUTE_FAIL=$((ROUTE_FAIL+1))
      fail "路由错误: 请求=$MODEL 响应 model=$RESP_MODEL"
    fi
  done
done

if [[ $ROUTE_FAIL -eq 0 ]]; then
  ok "路由正确性通过（${ROUTE_PASS} 次全部路由到正确模型）"
else
  fail "路由正确性失败（${ROUTE_FAIL} 次错误）"
fi

# ── 阶段二：单模型基线 ─────────────────────────────────────────────
echo ""
echo "▶ 阶段二：单模型基线（顺序压测，无竞争）"

declare -A BASE_P50 BASE_P90 BASE_TPS
for MODEL in "${MODELS[@]}"; do
  OUTFILE="$TMPDIR_BENCH/baseline_${MODEL}.txt"
  python3 "$TMPDIR_BENCH/bench.py" "$ENDPOINT" "$MODEL" \
    "$CONCURRENCY" "$REQUESTS" "$MAX_TOKENS" "$OUTFILE"
  read OK TOTAL P50 P90 TPS ROUTING_OK < "$OUTFILE"
  BASE_P50[$MODEL]=$P50
  BASE_P90[$MODEL]=$P90
  BASE_TPS[$MODEL]=$TPS
  echo "  $MODEL: $OK/$TOTAL 成功  TTFT p50=${P50}ms p90=${P90}ms  TPS=${TPS} tok/s"
done

# ── 阶段三：多模型并发 ─────────────────────────────────────────────
echo ""
echo "▶ 阶段三：多模型并发（同时压测，观察资源竞争）"

PIDS=()
for MODEL in "${MODELS[@]}"; do
  OUTFILE="$TMPDIR_BENCH/concurrent_${MODEL}.txt"
  python3 "$TMPDIR_BENCH/bench.py" "$ENDPOINT" "$MODEL" \
    "$CONCURRENCY" "$REQUESTS" "$MAX_TOKENS" "$OUTFILE" &
  PIDS+=($!)
done
for PID in "${PIDS[@]}"; do wait "$PID"; done

echo ""
echo "  结果对比（基线 → 并发）："
echo "  ──────────────────────────────────────────────────────"

ALL_OK=true
for MODEL in "${MODELS[@]}"; do
  OUTFILE="$TMPDIR_BENCH/concurrent_${MODEL}.txt"
  read OK TOTAL P50 P90 TPS ROUTING_OK < "$OUTFILE"

  B50="${BASE_P50[$MODEL]}"
  BTPS="${BASE_TPS[$MODEL]}"

  # 计算变化
  if [[ "$B50" -gt 0 && "$P50" -gt 0 ]]; then
    DELTA_TTFT=$(python3 -c "print(f'{($P50-$B50)/$B50*100:+.0f}%')" 2>/dev/null || echo "")
    DELTA_TPS=$(python3 -c "print(f'{($TPS-$BTPS)/$BTPS*100:+.0f}%')" 2>/dev/null || echo "")
  else
    DELTA_TTFT=""; DELTA_TPS=""
  fi

  if [[ "$ROUTING_OK" == "$OK" ]]; then
    ROUTE_STATUS="✅"
  else
    ROUTE_STATUS="❌(路由错误${ROUTING_OK}/${OK})"
    ALL_OK=false
  fi

  echo "  $MODEL:"
  echo "    成功率:    $OK/$TOTAL"
  echo "    TTFT p50:  ${P50}ms  (基线=${B50}ms $DELTA_TTFT)"
  echo "    TTFT p90:  ${P90}ms  (基线=${BASE_P90[$MODEL]}ms)"
  echo "    TPS:       ${TPS} tok/s  (基线=${BTPS} tok/s $DELTA_TPS)"
  echo "    路由:      $ROUTE_STATUS"
  echo ""
done

echo "  ──────────────────────────────────────────────────────"

# ── 总结 ──────────────────────────────────────────────────────────
echo ""
echo "▶ 总结"
if $ALL_OK; then
  ok "路由隔离正常：两个模型未发生跨池路由"
else
  fail "路由隔离异常：发现跨池路由错误！"
fi

echo ""
echo "  基线 vs 并发 TTFT p50 对比："
for MODEL in "${MODELS[@]}"; do
  read OK TOTAL P50 P90 TPS ROUTING_OK < "$TMPDIR_BENCH/concurrent_${MODEL}.txt"
  B50="${BASE_P50[$MODEL]}"
  if [[ "$B50" -gt 0 && "$P50" -gt 0 ]]; then
    IMPACT=$(python3 -c "
d=($P50-$B50)/$B50*100
print(f'  +{d:.0f}% 变慢（多模型竞争影响）' if d>10 else f'  +{d:.0f}% 基本无影响' if d>=0 else f'  {d:.0f}% 变快')" 2>/dev/null || echo "")
    echo "  $MODEL: 基线 ${B50}ms → 并发 ${P50}ms${IMPACT}"
  fi
done

echo ""
echo "================================================================"
echo "  如需完整吞吐压测: bash measure-tpm.sh --data-type shared_prefix"
echo "================================================================"
