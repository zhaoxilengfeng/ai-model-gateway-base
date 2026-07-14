#!/usr/bin/env python3
"""
将 qwen-bailian-usagetraces-anon 的 flat JSONL 格式
转换为 inference-perf weka_trace_replay 所需的 WekaTrace JSON 格式

多轮关系通过 parent_chat_id 链接：
  parent_chat_id == -1 表示 session 起始轮
  parent_chat_id == X  表示本轮的上一轮是 chat_id=X

用法:
  python3 convert_qwen_trace.py <input.jsonl> <output_dir> [--block-size 16] [--max-sessions 200]
"""
import json
import argparse
import sys
from pathlib import Path

def build_chains(rows):
    by_id = {r['chat_id']: r for r in rows}
    children = {}
    for r in rows:
        p = r['parent_chat_id']
        if p != -1:
            children.setdefault(p, []).append(r['chat_id'])

    sessions = []
    for r in rows:
        if r['parent_chat_id'] == -1:
            chain = []
            stack = [r['chat_id']]
            while stack:
                cid = stack.pop(0)
                chain.append(by_id[cid])
                for child in children.get(cid, []):
                    stack.append(child)
            sessions.append(chain)
    return sessions

def convert(input_file: str, output_dir: str, block_size: int = 16, max_sessions: int = None,
            max_input_len: int = 7680):
    input_path = Path(input_file)
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    rows = []
    with open(input_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception as e:
                print(f"[WARN] skip line: {e}", file=sys.stderr)

    sessions = build_chains(rows)
    if max_sessions:
        sessions = sessions[:max_sessions]

    # 过滤超出 max_input_len 的 session（避免超出 vLLM max-model-len）
    filtered = [s for s in sessions if all(r['input_length'] <= max_input_len for r in s)]
    skipped = len(sessions) - len(filtered)
    if skipped:
        print(f"[INFO] 过滤掉 {skipped} 个含超长请求的 session（input_length > {max_input_len}）")
    sessions = filtered

    print(f"总请求数: {len(rows)}，还原 session 数: {len(sessions)}")

    converted = 0
    for idx, chain in enumerate(sessions):
        requests = []
        t = 0.0
        for req in chain:
            requests.append({
                "t": req.get('timestamp', t),
                "type": "n",
                "model": "qwen-coder",
                "in": req['input_length'],
                "out": req['output_length'],
                "hash_ids": req.get('hash_ids', [])
            })
            t = req.get('timestamp', t)

        trace = {
            "id": f"session-{idx:06d}",
            "models": ["qwen-coder"],
            "block_size": block_size,
            "requests": requests
        }

        out_file = output_path / f"session_{idx:06d}.json"
        with open(out_file, 'w') as f:
            json.dump(trace, f)
        converted += 1

    print(f"已转换 {converted} 个 session 到 {output_path}")

    all_turns = [len(s) for s in sessions]
    all_in = [r['input_length'] for s in sessions for r in s]
    all_out = [r['output_length'] for s in sessions for r in s]
    multi = [t for t in all_turns if t > 1]
    print(f"统计：")
    print(f"  轮次/session: min={min(all_turns)} max={max(all_turns)} mean={sum(all_turns)/len(all_turns):.1f}")
    print(f"  多轮 session 数: {len(multi)} ({len(multi)/len(all_turns)*100:.1f}%)")
    print(f"  输入 tokens:  min={min(all_in)} max={max(all_in)} mean={sum(all_in)/len(all_in):.0f}")
    print(f"  输出 tokens:  min={min(all_out)} max={max(all_out)} mean={sum(all_out)/len(all_out):.0f}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Convert Qwen Bailian trace to Weka format')
    parser.add_argument('input', help='Input JSONL file')
    parser.add_argument('output_dir', help='Output directory for JSON files')
    parser.add_argument('--block-size', type=int, default=16)
    parser.add_argument('--max-sessions', type=int, default=None)
    parser.add_argument('--max-input-len', type=int, default=7680,
                        help='过滤掉 input_length 超过此值的 session（默认 7680，为 max-model-len=8192 留 512 给输出）')
    args = parser.parse_args()
    convert(args.input, args.output_dir, args.block_size, args.max_sessions, args.max_input_len)
