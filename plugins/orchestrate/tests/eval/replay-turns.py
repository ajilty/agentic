#!/usr/bin/env python3
"""Drive several turns through ONE headless `claude` process (tests/eval/replay.sh).

    replay-turns.py [--split FILE] [--lines FILE ...] <out-prefix> <turn-file> ... -- <claude argv>

Runs the claude argv with stream-json input and output, sends each turn file's
text as one user message, waits for that turn's `result` event before sending
the next, then closes stdin.

Why one process: a compaction re-attaches the skills invoked so far, but only
the ones the compacting process itself saw invoked. Probed on 2.1.322: `/compact`
sent in the same process wrote an `invoked_skills` attachment carrying the first
~5,000 tokens of the skill; the same `/compact` sent from a separate `--resume`
process wrote none. Forcing the compaction on a resumed run would measure the
harness, not the router.

Writes <out-prefix>.stream.jsonl (every event) and <out-prefix>.<n>.json (turn
n's result event, from 1, plus `_lines`: line counts of each --lines FILE when
the turn ended). --split FILE moves FILE to FILE.turn<n> after turn n, so a log
the session appends to (the guard's) comes out one file per turn. The caller
owns the environment: run this under the same scrubbed `env -i` as any replay.
"""
import json, os, subprocess, sys

args, split, lines = sys.argv[1:], None, []
while args and args[0] in ("--split", "--lines"):
    if args[0] == "--split": split = args[1]
    else: lines.append(args[1])
    args = args[2:]
cut = args.index("--")
prefix, turns, argv = args[0], args[1:cut], args[cut + 1:]
argv += ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]

def count(p):
    try: return sum(1 for _ in open(p))
    except Exception: return 0

with open(prefix + ".stream.jsonl", "w") as log:
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    for n, tf in enumerate(turns, 1):
        result = None
        try:
            p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": open(tf).read()}}) + "\n")
            p.stdin.flush()
        except (BrokenPipeError, OSError):
            pass                       # the process already ended (budget, timeout): no result
        else:
            for line in p.stdout:
                log.write(line); log.flush()
                try: ev = json.loads(line)
                except Exception: continue
                if ev.get("type") == "result":
                    result = ev; break
        result = result or {"is_error": True, "subtype": "no_result"}
        result["_lines"] = {f: count(f) for f in lines}
        with open("%s.%d.json" % (prefix, n), "w") as f: json.dump(result, f)
        if split and os.path.exists(split): os.replace(split, "%s.turn%d" % (split, n))
        if result.get("subtype") == "no_result": break
    try: p.stdin.close()
    except Exception: pass
    for line in p.stdout: log.write(line)
    sys.exit(p.wait())
