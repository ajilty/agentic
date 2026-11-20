#!/usr/bin/env python3
"""Litmus engine: run one real-delivery test session and report what happened.

Real delivery means the candidate text sits where Claude Code itself loads
instruction files, and reaches the model the way it would in a real session.
The engine reports facts only (the reply, the cost, which instruction files
loaded, any tool the session tried, any file it left). It does no grading and gives no verdict.

Each session gets its own folder under a run root that is outside the home
directory, outside /tmp and outside Claude Code's own scratch area:
  home/   a throwaway HOME: nothing of the operator's is in it
  work/   the working directory
  log/    what the two hooks below record
  cfg/    the settings file that wires the hooks
  tmp/    the session's temp directory
The candidate goes to work/CLAUDE.md (scope project), home/.claude/CLAUDE.md
(scope user) or work/.claude/rules/<name> (scope rules).

Isolation: the session starts from an empty environment plus a short allowlist
(clean_env), so nothing of the calling session rides along; the login is a
token passed by name, never written to disk. Two hooks ride in through
--settings: one records every instruction file Claude Code loads, the other
refuses every tool call, records it, and blocks the tool if the hook itself
fails. An @path in a prompt is not expanded into the file's contents. This is
not an operating-system boundary: the session still runs as the
caller's user with the network up. Runs that grant tools belong in the replay
harness's sandbox.

The load check: a run is sound only if exactly the candidate loaded. A missing
record can be a timing miss (the recording hook is asynchronous and a short
session may end first), so the caller may retry it; an extra file never is.
"""
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import subprocess
import time

MIN_CLI = (2, 1, 299)          # a hook can block the tool when the hook itself fails (2.1.295), and
                               # an @path in a prompt can be kept from pulling a file in (2.1.299)
AUTH_NAMES = ("CLAUDE_CODE_OAUTH_TOKEN",)
SOURCES = {"project": "project", "rules": "project", "user": "user"}
SABOTAGE = ("absent", "extra", "nolog")   # deliberate breaks, to prove the load check fires
DENY = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                               "permissionDecisionReason": "Tool calls are switched off in this session."}}
# Anything above the run root that Claude Code would treat as a project or load as instructions.
ABOVE_ROOT = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude", ".git")
MANAGED = ("/etc/claude-code/CLAUDE.md", "/Library/Application Support/ClaudeCode/CLAUDE.md")


class EngineError(Exception):
    """The engine cannot run a sound session as asked."""


def find_cli(cli=None):
    path = cli or shutil.which("claude")
    if not path or not os.path.isfile(path):
        raise EngineError("the claude CLI was not found")
    return os.path.realpath(path)


def require_cli(cli):
    """The CLI's version as text; refuses one too old to fail closed."""
    out = subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=60,
                         stdin=subprocess.DEVNULL).stdout
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", out)
    if not m or tuple(map(int, m.groups())) < MIN_CLI:
        raise EngineError(f"needs Claude Code {'.'.join(map(str, MIN_CLI))} or later (found {out.strip() or 'none'})")
    return m.group(0)


def check_run_root(root):
    """The real path of the run root; refuses a place where the wrong files would load."""
    real = os.path.realpath(root)
    home = os.path.realpath(os.path.expanduser("~"))
    for bad, why in ((home, "under the home directory, where parent instruction files load too"),
                     ("/tmp", "under /tmp"), ("/private/tmp", "under /tmp")):
        if real == bad or real.startswith(bad.rstrip("/") + "/"):
            raise EngineError(f"run root {real} is {why}")
    if re.search(r"(^|/)claude-\d+(/|$)", real):
        raise EngineError(f"run root {real} is inside Claude Code's own scratch area")
    d = pathlib.Path(real)
    for parent in (d, *d.parents):
        for name in ABOVE_ROOT:
            if (parent / name).exists():
                raise EngineError(f"{parent / name} sits above the run root: it would load too, or make the root part of a project")
    for path in MANAGED:
        if os.path.exists(path):
            raise EngineError(f"a managed instruction file loads into every session on this machine: {path}")
    return real


def clean_env(cli, home, tmp):
    """The whole environment of a test session. Nothing else is inherited."""
    auth = {k: os.environ[k] for k in AUTH_NAMES if os.environ.get(k)}
    if not auth:
        raise EngineError(f"no login for test sessions: set {' or '.join(AUTH_NAMES)} (a token from `claude setup-token`)")
    return {"HOME": str(home), "PATH": f"{os.path.dirname(cli)}:/usr/bin:/bin", "TERM": "dumb",
            "LANG": os.environ.get("LANG", "C.UTF-8"), "TMPDIR": str(tmp), "CLAUDE_CODE_TMPDIR": str(tmp),
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_FILE_MENTIONS": "1", **auth}


def place(run, text, scope, sabotage=None):
    """Build one session's folders and put the candidate where Claude Code loads it."""
    if scope not in SOURCES:
        raise EngineError(f"unknown scope {scope!r}")
    if sabotage not in (None, *SABOTAGE):
        raise EngineError(f"unknown sabotage {sabotage!r}")
    if scope == "rules" and re.match(r"---\n.*?^paths:.*?\n---", text, re.S | re.M):
        raise EngineError("a path-scoped rule loads only when a matching file is read; not supported yet")
    run = pathlib.Path(run)
    lay = {n: run / n for n in ("home", "work", "log", "cfg", "tmp")}
    for d in (lay["home"] / ".claude", lay["work"], lay["log"], lay["cfg"], lay["tmp"]):
        d.mkdir(parents=True)
    target = {"project": lay["work"] / "CLAUDE.md", "user": lay["home"] / ".claude" / "CLAUDE.md",
              "rules": lay["work"] / ".claude" / "rules" / "candidate.md"}[scope]
    if sabotage != "absent":
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
    if sabotage == "extra":
        extra = (lay["home"] / ".claude" / "rules" / "extra.md") if scope == "user" else (lay["work"] / ".claude" / "CLAUDE.md")
        extra.parent.mkdir(parents=True, exist_ok=True)
        extra.write_text("# Extra\n\nThis file is not the candidate.\n")
    q = shlex.quote
    loaded, tools = str(lay["log"] / "loaded.jsonl"), str(lay["log"] / "tools.jsonl")
    hooks = {"PreToolUse": [{"matcher": ".*", "hooks": [{
        "type": "command", "timeout": 10, "onFailure": "block",
        "command": f"cat >> {q(tools)}; echo >> {q(tools)}; printf '%s\\n' {q(json.dumps(DENY))}"}]}]}
    if sabotage != "nolog":
        hooks["InstructionsLoaded"] = [{"hooks": [{
            "type": "command", "timeout": 10, "command": f"cat >> {q(loaded)}; echo >> {q(loaded)}"}]}]
    (lay["cfg"] / "settings.json").write_text(json.dumps({"hooks": hooks}))
    return lay | {"target": target, "settings": lay["cfg"] / "settings.json"}


def read_records(path):
    """The JSON objects a hook appended to a file, however they were spaced."""
    try:
        s = pathlib.Path(path).read_text()
    except OSError:
        return []
    out, i, dec = [], 0, json.JSONDecoder()
    while i < len(s):
        if s[i].isspace():
            i += 1
            continue
        try:
            obj, i = dec.raw_decode(s, i)
        except ValueError:
            break
        if isinstance(obj, dict):
            out.append(obj)
    return out


def load_check(expected, loaded):
    """Exactly the candidate must have loaded: nothing missing, nothing extra."""
    want = {os.path.realpath(p) for p in expected}
    got = {os.path.realpath(r["file_path"]) for r in loaded if isinstance(r.get("file_path"), str)}
    return {"ok": want == got, "missing": sorted(want - got), "extra": sorted(got - want)}


def run_session(*, cli, run_root, name, text, scope, prompt, model, effort=None, sabotage=None,
                session_budget=0.25, timeout=180, keep=False):
    """Run one session and return its facts. The run root must have passed check_run_root."""
    run = pathlib.Path(run_root) / name
    if run.exists():
        shutil.rmtree(run)
    lay = place(run, text, scope, sabotage)
    env = clean_env(cli, lay["home"], lay["tmp"])
    cmd = [cli, "-p", "--model", model, "--setting-sources", SOURCES[scope], "--settings", str(lay["settings"]),
           "--no-session-persistence", "--output-format", "json", "--max-budget-usd", str(session_budget)]
    if effort:
        cmd += ["--effort", effort]
    facts = {"scope": scope, "model": model, "effort": effort, "sabotage": sabotage, "started": time.strftime("%F %T"),
             "exit_code": None, "timed_out": False, "result": "", "is_error": None, "cost_usd": 0.0, "cost_known": False, "tokens": {},
             "models": [],
             "num_turns": None, "stderr": ""}
    t0 = time.time()
    proc = subprocess.Popen(cmd, cwd=lay["work"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(prompt, timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)      # the session and anything it started
        except OSError:
            pass
        out, err = proc.communicate()
        facts["timed_out"] = True
    facts["seconds"] = round(time.time() - t0, 2)
    facts["exit_code"], facts["stderr"] = proc.returncode, (err or "")[-400:]
    try:
        d = json.loads(out)
    except ValueError:
        d = None
    # failed: the session itself did not complete, whatever it would have answered
    facts["failed"] = facts["timed_out"] or proc.returncode != 0 or not isinstance(d, dict) or bool(d.get("is_error"))
    if isinstance(d, dict):
        u = d.get("usage") if isinstance(d.get("usage"), dict) else {}
        cost = d.get("total_cost_usd")
        # a killed session reports none; anything but a finite sum of 0 or more is no report either
        facts["cost_known"] = isinstance(cost, (int, float)) and not isinstance(cost, bool) and 0 <= cost < 1e6
        facts.update(result=d.get("result") if isinstance(d.get("result"), str) else "",
                     is_error=d.get("is_error"), num_turns=d.get("num_turns"),
                     models=sorted(d["modelUsage"]) if isinstance(d.get("modelUsage"), dict) else [],
                     cost_usd=float(cost) if facts["cost_known"] else 0.0,
                     tokens={k: u.get(k, 0) for k in ("input_tokens", "output_tokens",
                                                      "cache_read_input_tokens", "cache_creation_input_tokens")})
    loaded = read_records(lay["log"] / "loaded.jsonl")
    facts["loaded"] = [{k: r.get(k) for k in ("file_path", "memory_type", "load_reason")} for r in loaded]
    facts["load"] = load_check([lay["target"]], loaded)
    facts["tool_attempts"] = [str(r.get("tool_name")) for r in read_records(lay["log"] / "tools.jsonl")]
    placed = {lay["target"], *lay["target"].parents, lay["work"] / ".claude", lay["work"] / ".claude" / "CLAUDE.md"}
    facts["left_behind"] = sorted(str(p.relative_to(lay["work"])) for p in lay["work"].rglob("*") if p not in placed)
    facts["run_dir"] = str(run)
    if not keep:
        shutil.rmtree(run, ignore_errors=True)
    return facts
