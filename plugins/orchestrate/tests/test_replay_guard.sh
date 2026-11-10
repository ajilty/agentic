# The replay harness's command guard (tests/eval/replay-guard.py). Best effort by design:
# the boundary is a session with no credentials. These pin what it does promise:
# dispatches, the network and paths outside the sandbox are refused, ordinary work in
# the sandbox is allowed, and its own errors block (exit 2) rather than let a tool run.
if ! command -v python3 >/dev/null 2>&1; then echo "(skip replay guard: no python3)"; else
_rg="$HERE/eval/replay-guard.py"; _rgd="$(mktemp -d)"; mkdir -p "$_rgd/sb"
_rg_run(){ printf '%s' "$1" | REPLAY_LOG="${2:-$_rgd/log.jsonl}" REPLAY_ROOTS="$_rgd/sb" python3 "$_rg" 2>/dev/null; }
_rg_is(){ # <want deny|allow> <json> <label>
  local out; out="$(_rg_run "$2")"; local rc=$?
  case "$1:$out" in deny:*'"deny"'*) pass ;; allow:) [ "$rc" = 0 ] && pass || fail "guard allows: $3 (rc=$rc)" ;; *) fail "guard should $1: $3" ;; esac
}
_rg_is deny  '{"tool_name":"Agent","tool_input":{"subagent_type":"orchestrate:researcher"}}' "a dispatch"
_rg_is deny  '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}' "the web"
_rg_is deny  '{"tool_name":"mcp__x__send","tool_input":{}}' "a connected service"
_rg_is deny  '{"tool_name":"Bash","tool_input":{"command":"git -C repo push origin main"}}' "git -C push"
_rg_is deny  '{"tool_name":"Bash","tool_input":{"command":"\"curl\" https://example.com"}}' "a quoted command word"
_rg_is deny  "{\"tool_name\":\"Glob\",\"tool_input\":{\"pattern\":\"/etc/**/*.conf\"}}" "an absolute Glob outside the sandbox"
_rg_is deny  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/etc/hostname\"}}" "a read outside the sandbox"
_rg_is allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"curl\" ."}}' "a search that names a tool"
_rg_is allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"push the fix\""}}' "a commit message that names push"
_rg_is allow "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$_rgd/sb/a.md\"}}" "a read inside the sandbox"
_rg_run '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "/nonexistent/dir/log.jsonl" >/dev/null; assert_eq "$?" 2 "guard error (unwritable log) blocks with exit 2"
printf 'not json' | REPLAY_LOG="$_rgd/log.jsonl" REPLAY_ROOTS="$_rgd/sb" python3 "$_rg" >/dev/null 2>&1; assert_eq "$?" 2 "guard error (bad input) blocks with exit 2"
grep -q '"onFailure":"block"' "$HERE/eval/replay.sh" && pass || fail "replay.sh wires the guard to block on a timeout or failure to start"
rm -rf "$_rgd"
fi
