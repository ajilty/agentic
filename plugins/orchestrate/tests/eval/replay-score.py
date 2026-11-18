#!/usr/bin/env python3
"""One scorecard line for one replay output directory (see replay.sh)."""
import glob, json, os, re, sys

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
try: res = json.load(open(o + "/result.json"))
except Exception: res = {}
if not isinstance(res, dict): res = {}
say = str(res.get("result", "") or "")
# Questions put to the operator in the closing message: question marks that end a
# sentence of prose, wherever the prose sits (a heading, a list item, a quote block).
# Not the router asking: code, table rows that start with a pipe, a bare link, and
# a question inside quotation marks (the operator's own, restated).
prose = re.sub(r"```.*?```|~~~.*?~~~|`[^`\n]*`", " ", say, flags=re.S)
prose = re.sub(r"\[([^\]\n]*)\]\([^)\n]*\)", r"\1", prose)   # a link keeps its text
prose = re.sub(r"https?://\S+", " ", prose)
said = sum(len(re.findall(r"\?(?=[\s*_):]|$)", l)) for l in prose.splitlines()
           if not re.match(r"\s*\||(?:\t| {4})(?![ \t]*(?:[-*+]|\d+[.)])\s)", l))
clar = ci is not None and (di is None or ci < di)   # the journal's own record of asking
if clar: out = "asked"
elif edits and first in (None, "verifier"): out = "inline"
elif first: out = "went:" + first
elif said: out = "asked"   # stopped with a question and started nothing, journaled or not
else: out = "idle"
tier = next((r.get("tier") for r in rows if r.get("event") == "intake"), None) or "-"
def num(k, fmt, scale=1):   # in post-compaction mode the session can write this file: a number or a dash
    v = res.get(k)
    return fmt % (v / scale) if isinstance(v, (int, float)) and not isinstance(v, bool) else "-"
kind = open(o + "/kind").read().strip() if os.path.exists(o + "/kind") else "-"
mu = res.get("modelUsage"); model = ",".join(sorted(map(str, mu))) if isinstance(mu, dict) and mu else "-"
read = "y" if glob.glob(o + "/tickets/*/reading.md") else "-"
verdict = "-"
for f in glob.glob(o + "/tickets/*/assessment.md"):
    m = re.search(r"VERDICT:\s*(\w+)", open(f).read())
    if m: verdict = m.group(1)
print("%-24s %-7s %-15s %-4s %-4s %-4s %-9s %-4d %-5d %-4d %-5s %-5s %s" % (
    os.path.basename(o), kind, out, "y" if clar else "-", tier, read, verdict, len(rows), edits, said,
    num("num_turns", "%d"), num("duration_ms", "%d", 1000), num("total_cost_usd", "$%.2f")))
