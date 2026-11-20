"""A stand-in for the claude CLI, for tests. No model, no network.

It does what the real CLI does that the engine relies on: finds instruction
files from the working directory and HOME according to --setting-sources, runs
the InstructionsLoaded and PreToolUse hooks from the --settings file, reads the
prompt on stdin and prints one result object. How it "answers" is steered by
plain markers in whatever instruction text it loaded:
  rate=0.9     chance of picking the option whose text contains RIGHT
  garble=0.5   chance of replying with something that cannot be graded
  garble_first_try=1   the first try at every answer cannot be graded, the retry can
  tool=1       try a tool before answering
It answers the probe's two questions as a model would: the code word if it was
given one, and a Write attempt when asked to create proof.txt.
control.json beside this file may set: version, env_dump (a file to append this
process's environment names to), skip_load_hook (never report what loaded),
skip_load_hook_after (report loading for only the first N sessions), fail
(every session ends in an error), fail_cost (the cost such a session reports), crash (every session
dies without a word), sleep (seconds before answering), no_tool
(never try a tool), model (the name of the model that "answered").
"""
import hashlib
import json
import os
import pathlib
import random
import re
import subprocess
import sys
import time

here = pathlib.Path(__file__).resolve().parent
try:
    control = json.loads((here / "control.json").read_text())
except OSError:
    control = {}

argv = sys.argv[1:]
if "--version" in argv:
    print(control.get("version", "2.1.327") + " (Claude Code)")
    sys.exit(0)


def opt(name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


sources = [s for s in (opt("--setting-sources", "user,project,local") or "").split(",") if s]
settings = json.loads(pathlib.Path(opt("--settings")).read_text()) if opt("--settings") else {}
prompt = sys.stdin.read()
cwd, home = pathlib.Path.cwd(), pathlib.Path(os.environ.get("HOME", "/nonexistent"))
time.sleep(control.get("sleep", 0))

with open(here / "count", "a") as fh:
    fh.write("x")
count = (here / "count").stat().st_size

if control.get("env_dump"):
    with open(control["env_dump"], "a") as fh:
        fh.write(json.dumps({"names": sorted(os.environ), "home": str(home), "cwd": str(cwd)}) + "\n")

if control.get("crash"):
    sys.exit(1)
if control.get("fail"):
    print(json.dumps({"type": "result", "subtype": "error", "is_error": True, "result": "API Error: 401 the login is not valid",
                      "total_cost_usd": control.get("fail_cost", 0.0)}))
    sys.exit(1)

files = []   # (path, memory type)
if "user" in sources:
    files += [(p, "User") for p in [home / ".claude" / "CLAUDE.md", *sorted((home / ".claude" / "rules").glob("*.md"))] if p.is_file()]
if "project" in sources:
    for d in [*reversed(cwd.parents), cwd]:
        files += [(p, "Project") for p in (d / "CLAUDE.md", d / ".claude" / "CLAUDE.md") if p.is_file()]
    files += [(p, "Project") for p in sorted((cwd / ".claude" / "rules").glob("*.md"))]


def hook(event, payload):
    out = ""
    for group in settings.get("hooks", {}).get(event, []):
        for h in group.get("hooks", []):
            r = subprocess.run(["bash", "-c", h["command"]], input=json.dumps(payload), capture_output=True, text=True)
            out += r.stdout
    return out


def try_tool(name, tool_input, effect):
    said = hook("PreToolUse", {"hook_event_name": "PreToolUse", "tool_name": name, "tool_input": tool_input})
    if '"deny"' not in said:
        effect()


after = control.get("skip_load_hook_after")
if not control.get("skip_load_hook") and not (after is not None and count > after):
    for path, kind in files:
        hook("InstructionsLoaded", {"hook_event_name": "InstructionsLoaded", "file_path": str(path),
                                    "memory_type": kind, "load_reason": "session_start"})

text = "\n".join(p.read_text() for p, _ in files)
mark = lambda name, default: float(m.group(1)) if (m := re.search(name + r"=([0-9.]+)", text)) else default
rng = random.Random(hashlib.sha256((prompt + text + str(home)).encode()).hexdigest())

if mark("tool", 0):
    try_tool("Bash", {"command": "id"}, lambda: (cwd / "TOOL-RAN").write_text("the tool was not refused\n"))

options = re.findall(r"^([a-h])\. (.*)$", prompt, re.M)
if "proof.txt" in prompt:
    if not control.get("no_tool"):
        try_tool("Write", {"file_path": str(cwd / "proof.txt"), "content": "done"}, lambda: (cwd / "proof.txt").write_text("done"))
    reply = "done"
elif "code word" in prompt:
    reply = "LANTERN" if "LANTERN" in text else "NONE"
elif not options:
    reply = "ok"
elif rng.random() < mark("garble", 0) or (mark("garble_first_try", 0) and home.parent.name.endswith("-0")):
    reply = "I would think about it."
else:
    right = [o for o in options if "RIGHT" in o[1]]
    wrong = [o for o in options if "RIGHT" not in o[1]]
    letter, chosen = (right or options)[0] if rng.random() < mark("rate", 0) else (wrong or options)[0]
    reply = json.dumps({"action": letter, "action_text": chosen, "reason": "stand-in"})

print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": reply, "num_turns": 1,
                  "total_cost_usd": 0.002, "modelUsage": {control.get("model", "stand-in-model-1"): {"costUSD": 0.002}},
                  "usage": {"input_tokens": 3, "output_tokens": 40,
                                                     "cache_read_input_tokens": 15000, "cache_creation_input_tokens": 4000}}))
