#!/usr/bin/env python3
"""One post-compaction scorecard line per replay output dir (replay.sh, REPLAY_POSTCOMPACT=1).

    replay-postcompact-score.py <out-dir>     one line
    replay-postcompact-score.py --header      the column names
    replay-postcompact-score.py --why <dir>   the probe sentences and where each was found

Columns:
  cmp     compaction evidenced by the transcript: y:<trigger> when a compact_boundary
          entry follows turn 1, then pre->post context tokens; "-" when none
  pre     router brief (skill.md) present in context BEFORE the compaction, hits per
          third (first/middle/last) of probe sentences: a control for the matcher
  post    the same probes in the context turn 2 started from
  hook    the SessionStart compact hook ran and its output reached turn 2's context:
          y:<chars>, ran-not-in-ctx, or "-" (did not run, or printed nothing)
  t1sk    turn 1 loaded the orchestrate skill (Skill tool)
  reinv   turn 2 re-invoked the orchestrate skill: skill, read (Read its SKILL.md), or "-"
  ledger  turn-2 Bash calls that ran ledger.sh
  rows2   journal rows written in turn 2; raw = turn-2 writes to board.jsonl that
          bypassed ledger.sh
  disp2   turn-2 dispatches (recorded and refused by the guard)
  t2$     turn-2 cost; total$ the whole process; secs the three turns' wall time
  src     where "post" was read: req = the request turn 2 sent, rebuilt from the
          transcript's api-request records; log = transcript entries between the
          boundary and turn 2's first reply (fallback when a record is missing)

A probe is a line of SKILL.md's body (50+ chars, no template variable), taken
evenly from each third; it counts as present when its first 70 characters,
whitespace-normalized, appear verbatim. A summary that quotes the brief would
count; one that paraphrases it would not.
"""
import glob, json, os, re, sys

COLS = "%-24s %-22s %-8s %-8s %-15s %-4s %-6s %-6s %-5s %-3s %-5s %-6s %-7s %-5s %s"
HEAD = ("run", "cmp", "pre", "post", "hook", "t1sk", "reinv", "ledger", "rows2", "raw", "disp2",
        "t2$", "total$", "secs", "src")
PER_THIRD, NEEDLE = 6, 70

def jl(p):
    out = []
    try:
        for l in open(p, errors="replace"):
            try: out.append(json.loads(l))
            except Exception: pass
    except Exception: pass
    return out

def jload(p):
    try: return json.load(open(p))
    except Exception: return {}

def norm(s): return re.sub(r"\s+", " ", s).strip()

def strings(x, out):
    if isinstance(x, str): out.append(x)
    elif isinstance(x, dict):
        for v in x.values(): strings(v, out)
    elif isinstance(x, list):
        for v in x: strings(v, out)
    return out

def text(objs): return norm(" ".join(strings(objs, [])))

def probes(skill):
    body = re.sub(r"\A---\n.*?\n---\n", "", skill, flags=re.S)
    cands, pos = [], 0
    for line in body.split("\n"):
        s = norm(line)
        if len(s) >= 50 and "${" not in s and not s.startswith(("|", "```")):
            cands.append((pos, s[:NEEDLE]))
        pos += len(line) + 1
    thirds = [[c for p, c in cands if k * len(body) / 3 <= p < (k + 1) * len(body) / 3] for k in range(3)]
    pick = lambda xs: [xs[int(i * len(xs) / PER_THIRD)] for i in range(min(PER_THIRD, len(xs)))]
    return [pick(t) for t in thirds]

def hits(ps, ctx):
    return "/".join("%d" % sum(1 for p in t if p in ctx) for t in ps) if ctx else "-"

def tool_uses(entries):
    for m in entries:
        if m.get("type") != "assistant" or m.get("isSidechain"): continue
        for b in (m.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                yield b.get("id"), b.get("name"), b.get("input") or {}

def is_orch_skill(i): return str(i.get("skill", "")).split(":")[-1] == "orchestrate"

def score(o):
    L = jl(o + "/transcript.jsonl")
    skill = open(o + "/skill.md", errors="replace").read() if os.path.exists(o + "/skill.md") else ""
    ps = probes(skill)
    bounds = [i for i, m in enumerate(L) if m.get("type") == "system" and m.get("subtype") == "compact_boundary"]
    b = bounds[-1] if bounds else None
    after = norm(open(o + "/after.md").read())[:60] if os.path.exists(o + "/after.md") else None

    def user_text(m):
        c = (m.get("message") or {}).get("content")
        if isinstance(c, list): c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
        return norm(c) if isinstance(c, str) else ""
    # Turn 2 starts at the first real user line after the boundary (the after.md text).
    t2 = None
    if b is not None:
        for i in range(b + 1, len(L)):
            m = L[i]
            if m.get("type") == "user" and not m.get("isMeta") and not m.get("isCompactSummary"):
                u = user_text(m)
                if u and not u.startswith("<") and (after is None or u.startswith(after[:30])):
                    t2 = i; break
    first_reply = next((i for i in range(t2 or 0, len(L)) if t2 is not None and L[i].get("type") == "assistant"), len(L))

    # Rebuild each request the session sent: messages = previous[:keep] + blobs(tail).
    blobs = {m.get("hash"): m.get("message") for m in L if m.get("type") == "api-request-blob"}
    reqs, prev = [], []
    for i, m in enumerate(L):
        if m.get("type") != "api-request": continue
        msgs = prev[:m.get("keep", 0)] + [blobs.get(h) for h in m.get("tail", [])]
        reqs.append((i, msgs)); prev = msgs
    def req_after(i):
        return next((ms for j, ms in reqs if j > i), None)
    src, post_ctx = "log", ""
    if t2 is not None:
        r = req_after(t2)
        if r is not None and all(x is not None for x in r):
            src, post_ctx = "req", text(r)
        else:
            post_ctx = text(L[b:first_reply])
    # Pre: everything logged from the start through the boundary (the skill body is a
    # meta user entry there); a control that the probes match the brief at all.
    pre_ctx = text(L[:b]) if b is not None else text(L)

    cmp_ = "-"
    if b is not None:
        cm = L[b].get("compactMetadata") or {}
        cmp_ = "y:%s %sk->%sk" % (cm.get("trigger", "?"), cm.get("preTokens", 0) // 1000, cm.get("postTokens", 0) // 1000)

    # A SessionStart hook's plain stdout lands in hook_success.content; JSON
    # additionalContext lands in a separate hook_additional_context attachment.
    hook = "-"
    if b is not None:
        said = []
        for m in L[b:first_reply]:
            a = m.get("attachment") or {}
            if m.get("type") != "attachment": continue
            if a.get("type") == "hook_additional_context":
                said += strings(a.get("content"), [])
            elif a.get("type") == "hook_success" and str(a.get("hookName", "")).startswith("SessionStart"):
                said.append(a.get("content") or "")
        c = norm(" ".join(said))
        if c: hook = ("y:%d" % len(c)) if c[:80] in post_ctx else "ran-not-in-ctx"

    pre_uses = list(tool_uses(L[:b] if b is not None else L))
    t2_uses = list(tool_uses(L[t2:])) if t2 is not None else []
    t1sk = "y" if any(n == "Skill" and is_orch_skill(i) for _, n, i in pre_uses) else "-"
    reinv = "skill" if any(n == "Skill" and is_orch_skill(i) for _, n, i in t2_uses) else \
            "read" if any(n == "Read" and str(i.get("file_path", "")).endswith("skills/orchestrate/SKILL.md") for _, n, i in t2_uses) else "-"
    ledger = sum(1 for _, n, i in t2_uses if n == "Bash" and "ledger.sh" in str(i.get("command", "")))
    raw = sum(1 for _, n, i in t2_uses if
              (n in ("Write", "Edit") and str(i.get("file_path", "")).endswith("board.jsonl")) or
              (n == "Bash" and "board.jsonl" in str(i.get("command", "")) and "ledger.sh" not in str(i.get("command", ""))
               and re.search(r">>?\s*\S*board\.jsonl", str(i.get("command", "")))))
    rows2 = len(jl(o + "/journal.turn2.jsonl"))
    disp2 = sum(1 for g in jl(o + "/guard.turn2.jsonl") if g.get("tool") in ("Agent", "Task") and g.get("decision") == "deny")

    r1, rc, r2 = jload(o + "/result.json"), jload(o + "/compact.result.json"), jload(o + "/turn2.result.json")
    total = r2.get("total_cost_usd") or rc.get("total_cost_usd") or r1.get("total_cost_usd") or 0
    t2cost = (r2.get("total_cost_usd") or 0) - (rc.get("total_cost_usd") or 0) if r2.get("total_cost_usd") else 0
    secs = sum(int((r.get("duration_ms") or 0) / 1000) for r in (r1, rc, r2))
    if r2.get("is_error") or not r2: src += ",t2:" + str(r2.get("subtype", "missing"))
    row = (os.path.basename(o), cmp_, hits(ps, pre_ctx), hits(ps, post_ctx) if t2 is not None else "-", hook, t1sk, reinv,
           ledger, rows2, raw, disp2, "$%.2f" % t2cost, "$%.2f" % total, secs, src)
    return row, ps, pre_ctx, post_ctx

if __name__ == "__main__":
    if sys.argv[1] == "--header":
        print(COLS % HEAD)
    elif sys.argv[1] == "--why":
        row, ps, pre, post = score(sys.argv[2].rstrip("/"))
        for k, t in enumerate(ps):
            for p in t:
                print("third%d pre=%s post=%s  %s" % (k + 1, "y" if p in pre else "-", "y" if p in post else "-", p))
    else:
        print(COLS % score(sys.argv[1].rstrip("/"))[0])
