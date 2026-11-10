#!/usr/bin/env bash
# The replay guard (guard.py). Best effort by design: the boundary is a session
# with no credentials. These pin what it does promise: dispatches, the network
# and paths outside the sandbox are refused, ordinary work in the sandbox is
# allowed, and its own errors block (exit 2) rather than let a tool run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "(skip replay guard: no python3)"; exit 0; }
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); }; fail(){ FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
g="$HERE/guard.py"; d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT; mkdir -p "$d/sb"
run(){ printf '%s' "$1" | REPLAY_ALLOW_AGENTS="${3:-}" REPLAY_LOG="${2:-$d/log.jsonl}" REPLAY_ROOTS="$d/sb" python3 "$g" 2>/dev/null; }
is(){ # <want deny|allow> <json> <label> [allowed agents]
  local out rc; out="$(run "$2" "" "${4:-}")"; rc=$?
  case "$1:$out" in deny:*'"deny"'*) pass ;; allow:) [ "$rc" = 0 ] && pass || fail "guard allows: $3 (rc=$rc)" ;; *) fail "guard should $1: $3" ;; esac
}
is deny  '{"tool_name":"Agent","tool_input":{"subagent_type":"someplugin:researcher"}}' "a dispatch"
is allow '{"tool_name":"Agent","tool_input":{"subagent_type":"someplugin:researcher"}}' "a dispatch to an allowed subagent" researcher
is deny  '{"tool_name":"Agent","tool_input":{"subagent_type":"someplugin:builder"}}' "a dispatch outside the allow list" researcher
is deny  '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}' "the web"
is deny  '{"tool_name":"mcp__x__send","tool_input":{}}' "a connected service"
is deny  '{"tool_name":"Bash","tool_input":{"command":"git -C repo push origin main"}}' "git -C push"
is deny  '{"tool_name":"Bash","tool_input":{"command":"\"curl\" https://example.com"}}' "a quoted command word"
is deny  '{"tool_name":"Glob","tool_input":{"pattern":"/etc/**/*.conf"}}' "an absolute Glob outside the sandbox"
is deny  '{"tool_name":"Read","tool_input":{"file_path":"/etc/hostname"}}' "a read outside the sandbox"
is allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"curl\" ."}}' "a search that names a tool"
is allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"push the fix\""}}' "a commit message that names push"
is allow "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$d/sb/a.md\"}}" "a read inside the sandbox"
run '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "/nonexistent/dir/log.jsonl" >/dev/null; [ $? = 2 ] && pass || fail "guard error (unwritable log) blocks with exit 2"
printf 'not json' | REPLAY_LOG="$d/log.jsonl" REPLAY_ROOTS="$d/sb" python3 "$g" >/dev/null 2>&1; [ $? = 2 ] && pass || fail "guard error (bad input) blocks with exit 2"
grep -q '"onFailure":"block"' "$HERE/replay.sh" && pass || fail "replay.sh wires the guard to block on a timeout or failure to start"
bash -n "$HERE/replay.sh" && pass || fail "replay.sh parses"
echo "replay: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
