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
is deny  '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/curl https://example.com"}}' "a command given by path"
is deny  '{"tool_name":"Bash","tool_input":{"command":"command curl https://example.com"}}' "a command behind command"
is deny  '{"tool_name":"Bash","tool_input":{"command":"cat /proc/1/environ"}}' "another process's environment"
is deny  '{"tool_name":"Bash","tool_input":{"command":"cat ../../../../../etc/hostname"}}' "a path that climbs out with .."
is deny  '{"tool_name":"Bash","tool_input":{"command":"cd / && ls"}}' "cd to the root"
is deny  '{"tool_name":"Artifact","tool_input":{}}' "a tool the guard does not know"
is allow '{"tool_name":"Skill","tool_input":{"skill":"x"}}' "loading a skill"
is allow '{"tool_name":"Bash","tool_input":{"command":"ls ./src && cat a/b.md"}}' "relative paths inside the sandbox"
is allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"curl\" ."}}' "a search that names a tool"
is allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"push the fix\""}}' "a commit message that names push"
is allow "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$d/sb/a.md\"}}" "a read inside the sandbox"
run '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "/nonexistent/dir/log.jsonl" >/dev/null; [ $? = 2 ] && pass || fail "guard error (unwritable log) blocks with exit 2"
printf 'not json' | REPLAY_LOG="$d/log.jsonl" REPLAY_ROOTS="$d/sb" python3 "$g" >/dev/null 2>&1; [ $? = 2 ] && pass || fail "guard error (bad input) blocks with exit 2"
grep -q '"onFailure":"block"' "$HERE/replay.sh" && pass || fail "replay.sh wires the guard to block on a timeout or failure to start"
bash -n "$HERE/replay.sh" && pass || fail "replay.sh parses"
grep -q '"matcher":"\.\*"' "$HERE/replay.sh" && pass || fail "every tool call goes through the guard"

# The runner end to end, with a stand-in for the CLI (no model, no cost): it
# reports what a session could reach, changes a file and appends a journal row.
mkdir -p "$d/bin" "$d/src" "$d/set/one" "$d/plug"
cat > "$d/bin/claude" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "2.1.999 (Claude Code)"; exit 0; }
cat >/dev/null
echo change > new.txt; mkdir -p log; echo '{"event":"x"}' >> log/journal.jsonl
home="$(ls -A "$REAL_HOME_PROBE" 2>/dev/null | wc -l | tr -d ' ')"
canary="$(cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep -c '^REPLAY_CANARY=')"
outside="$(touch "$OUTSIDE_PROBE" 2>/dev/null && echo writable || echo readonly)"
printf '{"result":"home=%s canary=%s outside=%s","num_turns":1,"duration_ms":1000,"total_cost_usd":0}\n' "$home" "$canary" "$outside"
FAKE
chmod +x "$d/bin/claude"
( cd "$d/src" && git init -q && git config user.email t@t && git config user.name t && mkdir log \
  && echo '{"event":"old"}' > log/journal.jsonl && echo a > a.txt && git add a.txt log/journal.jsonl && git commit -qm init ) >/dev/null 2>&1
git -C "$d/src" rev-parse HEAD > "$d/set/one/commit"; echo "an ask" > "$d/set/one/ask.md"; echo note > "$d/set/one/kind"
# The stand-in reads these two names from its own file, since its environment is scrubbed.
sed -i.bak -e "s|\$REAL_HOME_PROBE|$(cd "$HOME" && pwd -P)|" -e "s|\$OUTSIDE_PROBE|$d/outside|" "$d/bin/claude"
rp(){ REPLAY_CANARY=leak ANTHROPIC_API_KEY=x PATH="$d/bin:$PATH" REPLAY_PLUGIN_DIR="$d/plug" REPLAY_PREFIX='/go ' \
        REPLAY_JOURNAL=log/journal.jsonl REPLAY_IGNORE=log/ "$@" bash "$HERE/replay.sh" "$d/set" "$d/src" "$d/out" 2>&1; }
o="$d/out/one.1"
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true 2>/dev/null; then
  rp env >/dev/null
  [ "$(cat "$o/say.md" 2>/dev/null)" = "home=0 canary=0 outside=readonly" ] && pass \
    || fail "sandbox hides the home directory and the caller's environment, and is read-only outside (got: $(cat "$o/say.md" 2>/dev/null))"
else
  echo "(skip sandbox probe: no usable bwrap)"
  rp env | grep -q 'no usable bubblewrap' && pass || fail "without bubblewrap the runner refuses unless told otherwise"
  rp env REPLAY_UNCONFINED=1 >/dev/null
fi
[ "$(cat "$o/turn1.md" 2>/dev/null)" = "/go an ask" ] && pass || fail "the prefix and the ask are sent verbatim"
[ "$(cat "$o/changed-files.txt" 2>/dev/null)" = new.txt ] && pass || fail "changed files exclude run state (got: $(cat "$o/changed-files.txt" 2>/dev/null | tr '\n' ' '))"
[ "$(cat "$o/journal.jsonl" 2>/dev/null)" = '{"event":"x"}' ] && pass || fail "the journal keeps only this run's rows"
[ -f "$o/kind" ] && [ ! -f "$o/commit" ] && pass || fail "extra case files are copied out"
[ ! -e "$d/src/new.txt" ] && [ -z "$(git -C "$d/src" status --porcelain)" ] && pass || fail "the source repo is untouched"
echo stale > "$o/stale"; rp env REPLAY_UNCONFINED=1 >/dev/null; [ ! -e "$o/stale" ] && pass || fail "a rerun replaces the output directory"
echo "replay: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
