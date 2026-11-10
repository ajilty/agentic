#!/usr/bin/env python3
"""PreToolUse guard for scripts/replay/replay.sh.

A replay asks what a session does with an ask, not what its subagents or the
outside world do with it. So every dispatch is recorded and refused, and the
session is steered back into its sandbox. The source repo is a real project;
its snapshot must never reach the real thing.

This guard is best effort, not a boundary (it fails closed: its own errors exit
2, and replay.sh sets the hook to block on a timeout or a failure to start). It
pattern-matches commands, and a shell has more spellings than a pattern has
cases. What actually keeps a replay harmless is set up by replay.sh: a scrubbed
environment and a throwaway HOME, so the session holds no cloud, vault, SSH or
git-remote credential to misuse.

Env: REPLAY_LOG (jsonl log), REPLAY_ROOTS (colon-separated allowed path roots).
"""
import json, os, re, sys

def _closed(kind, value, tb):
    # Fail closed: an uncaught error would exit 1, which the harness treats as a
    # non-blocking hook error and runs the tool anyway. Exit 2 blocks it.
    sys.stderr.write("Replay harness: guard error (%s), tool refused.\n" % value); os._exit(2)
sys.excepthook = _closed

ev = json.load(sys.stdin)
tool, inp = ev.get("tool_name", ""), ev.get("tool_input", {})
if not isinstance(inp, dict): inp = {}
roots = [os.path.realpath(r) for r in os.environ.get("REPLAY_ROOTS", "").split(":") if r]

def log(decision, why=""):
    with open(os.environ["REPLAY_LOG"], "a") as f:
        f.write(json.dumps({"tool": tool, "decision": decision, "why": why, "input": inp}) + "\n")

def deny(why):
    log("deny", why)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
          "permissionDecision": "deny", "permissionDecisionReason": why}}))
    sys.exit(0)

def inside(p):
    p = os.path.realpath(os.path.join(ev.get("cwd", "."), os.path.expanduser(p)))
    return any(p == r or p.startswith(r + os.sep) for r in roots)

# REPLAY_ALLOW_AGENTS names read-only subagents that may really run (matched on
# the name after any plugin prefix); their own tool calls come back through this guard.
allowed = [a for a in os.environ.get("REPLAY_ALLOW_AGENTS", "").split(",") if a]
if tool in ("Agent", "Task") and str(inp.get("subagent_type", "")).split(":")[-1] in allowed:
    log("allow", "allowed subagent"); sys.exit(0)
if tool in ("Agent", "Task"):
    deny("Replay harness: dispatches are recorded, not run. End your turn now.")

# Connected services and the open web: the sandbox HOME carries the account's
# credential, so account-level connectors (mail, chat, drive) are visible to the
# session. Refused here by name, not left to the headless allow-list.
if tool.startswith("mcp__") or tool in ("WebFetch", "WebSearch"):
    deny("Replay harness: connected services and the web are off limits in this sandbox.")

if tool == "Bash":
    cmd = inp.get("command", "")
    # Anything that can reach a network, a cloud, a cluster, or a credential store.
    # Matched at command position only (line start, after ; & | ( ` $( or a wrapper),
    # so a search pattern that merely mentions a tool is not refused. This is the
    # second line of defence: the session's environment carries no credentials.
    risky = (r"(^|[;&|(`\n]|\$\()\s*((sudo|env|nohup|time|exec|command|builtin|xargs( -\S+)*|timeout \S+)\s+|(ba)?sh -c\s+['\"]?\s*)*"
             r"(\w+=\S*\s+)*\\?(?:\S*/)?(aws|terraform|tofu|kubectl|helm|flux|talosctl|gh|ssh|scp|rsync|curl|wget|nc|op|"
             r"just|nix|nixos-rebuild|ansible[\w-]*|pulumi|docker|podman|sops|with-secrets|sudo|pip|npm|npx|brew)(\s|$)")
    # Judge the commands, not the text they carry: drop heredoc bodies and quoted
    # strings (a commit message or a search pattern may name any tool), but keep
    # what a nested `sh -c '...'` would run.
    bare = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?.*?\n\s*\1\b", " ", cmd, flags=re.S)
    nested = [m[1] for m in re.findall(r"(?:ba)?sh\s+-c\s+(['\"])(.*?)\1", bare, flags=re.S)]
    # A quoted bare word is still that word to the shell ("curl" runs curl).
    bare = re.sub(r"(['\"])([\w./-]+)\1", r"\2", bare)
    bare = re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", " Q ", bare)
    for part in [bare] + nested:
        if re.search(risky, part) or re.search(
                r"\bgit\s+(?:-\S+\s+(?:[^-\s]\S*\s+)?)*(push|fetch|pull|clone|ls-remote|submodule|remote\s+(add|set-url|update))\b", part):
            deny("Replay harness: this sandbox has no network, cloud, or credential access.")
    # Paths outside the sandbox (the operator's real home above all): absolute
    # ones, ones that climb with .., and a bare `cd /`.
    for p in re.findall(r"(?<![\w.-])(/(?:var/home|home|Users|root|etc|proc|mnt|media|run/user|private)[^\s'\";|&)]*"
                        r"|~[^\s'\";|&)]*|(?:\.\./)+[^\s'\";|&)]*|\.\.(?=[\s'\";|&)]|$)|(?<=\bcd\s)/(?=[\s;|&)]|$))", cmd):
        if not inside(p):
            deny("Replay harness: paths outside the sandbox are off limits.")
    log("allow"); sys.exit(0)

# Any tool this guard does not know is refused: a tool it cannot judge must not
# run. The ones below only read or write under a path, or touch nothing outside.
if tool not in ("Read", "Write", "Edit", "Glob", "Grep", "NotebookEdit", "Skill", "ToolSearch", "TodoWrite",
                "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode"):
    deny("Replay harness: this tool is not available in this sandbox.")
for key in ("file_path", "path", "notebook_path"):
    p = inp.get(key)
    if p and not inside(p):
        deny("Replay harness: paths outside the sandbox are off limits.")
# A Glob pattern may itself be absolute; judge the part before its first wildcard.
pat = str(inp.get("pattern", "")) if tool == "Glob" else ""
if pat[:1] in ("/", "~") and not inside(re.split(r"[*?\[{]", pat)[0].rstrip("/") or "/"):
    deny("Replay harness: paths outside the sandbox are off limits.")
log("allow")
