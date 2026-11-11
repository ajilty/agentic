#!/usr/bin/env python3
"""One scorecard line for one replay output directory (see replay.sh)."""
import json, os, sys

o = sys.argv[1].rstrip("/")

def jl(p):
    out = []
    try:
        for l in open(p):
            try: r = json.loads(l)
            except Exception: continue
            if isinstance(r, dict): out.append(r)   # the session wrote these files: a row is an object or nothing
    except Exception: pass
    return out

rows, guard = jl(o + "/journal.jsonl"), jl(o + "/guard.jsonl")
ev = [r.get("event") for r in rows]
ci = ev.index("clarify") if "clarify" in ev else None
di = ev.index("dispatched") if "dispatched" in ev else None
agents = [g for g in guard if g.get("tool") in ("Agent", "Task") and g.get("decision") == "deny"]
inp = agents[0].get("input") if agents else None
first = str(inp.get("subagent_type", "?") if isinstance(inp, dict) else "?").split(":")[-1] if agents else None
try: edits = sum(1 for l in open(o + "/changed-files.txt") if l.strip())
except Exception: edits = 0
if ci is not None and (di is None or ci < di): out = "asked"
elif edits and first in (None, "verifier"): out = "inline"
elif first: out = "went:" + first
else: out = "idle"
tier = next((r.get("tier") for r in rows if r.get("event") == "intake"), None) or "-"
try: res = json.load(open(o + "/result.json"))
except Exception: res = {}
if not isinstance(res, dict): res = {}
def num(k, fmt, scale=1):   # in post-compaction mode the session can write this file: a number or a dash
    v = res.get(k)
    return fmt % (v / scale) if isinstance(v, (int, float)) and not isinstance(v, bool) else "-"
say = str(res.get("result", "") or "")
kind = open(o + "/kind").read().strip() if os.path.exists(o + "/kind") else "-"
mu = res.get("modelUsage"); model = ",".join(sorted(map(str, mu))) if isinstance(mu, dict) and mu else "-"
import glob, re
read = "y" if glob.glob(o + "/tickets/*/reading.md") else "-"
verdict = "-"
for f in glob.glob(o + "/tickets/*/assessment.md"):
    m = re.search(r"VERDICT:\s*(\w+)", open(f).read())
    if m: verdict = m.group(1)
print("%-24s %-7s %-15s %-4s %-4s %-9s %-4d %-5d %-4d %-5s %-5s %s" % (
    os.path.basename(o), kind, out, tier, read, verdict, len(rows), edits, say.count("?"),
    num("num_turns", "%d"), num("duration_ms", "%d", 1000), num("total_cost_usd", "$%.2f")))
