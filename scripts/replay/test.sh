#!/usr/bin/env bash
# The replay harness without a model: what the guard (guard.py) promises, and
# the runner (replay.sh) end to end with a stand-in for the CLI, including that
# the sandbox keeps a session away from the caller's files and environment.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "(skip replay tests: no python3)"; exit 0; }
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); }; fail(){ FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
g="$HERE/guard.py"; d="$(mktemp -d)"; d="$(cd "$d" && pwd -P)"; fh=""
trap '[ -n "$d" ] && rm -rf "$d"; [ -n "$fh" ] && rm -rf "$fh"' EXIT
mkdir -p "$d/sb"

# --- The guard. Best effort by design: these pin what it does promise.
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
is deny  '{"tool_name":"Artifact","tool_input":{}}' "a tool the guard does not know"
is deny  '{"tool_name":"Bash","tool_input":{"command":"git -C repo push origin main"}}' "git -C push"
is deny  '{"tool_name":"Bash","tool_input":{"command":"\"curl\" https://example.com"}}' "a quoted command word"
is deny  '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/curl https://example.com"}}' "a command given by path"
is deny  '{"tool_name":"Bash","tool_input":{"command":"command curl https://example.com"}}' "a command behind command"
is deny  '{"tool_name":"Bash","tool_input":{"command":"cat /proc/1/environ"}}' "another process's environment"
is deny  '{"tool_name":"Bash","tool_input":{"command":"echo {} > .claude/settings.json"}}' "rewriting the session's own settings from the shell"
is deny  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$d/sb/.claude/settings.local.json\"}}" "rewriting the session's own settings"
is deny  '{"tool_name":"Glob","tool_input":{"pattern":"/etc/**/*.conf"}}' "an absolute Glob outside the sandbox"
is deny  '{"tool_name":"Read","tool_input":{"file_path":"/etc/hostname"}}' "a read outside the sandbox"
is allow '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"curl\" ."}}' "a search that names a tool"
is allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"push the fix\""}}' "a commit message that names push"
is allow '{"tool_name":"Bash","tool_input":{"command":"cd src && cat ../README.md"}}' "a relative path after a cd"
is allow '{"tool_name":"Bash","tool_input":{"command":"/home/linuxbrew/.linuxbrew/bin/python3 -V"}}' "a tool installed under the package manager's own home"
is allow '{"tool_name":"Bash","tool_input":{"command":"sleep 1","run_in_background":true}}' "a background command"
is allow '{"tool_name":"TaskOutput","tool_input":{"task_id":"x"}}' "reading a background command's output"
is allow '{"tool_name":"Skill","tool_input":{"skill":"x"}}' "loading a skill"
is allow "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$d/sb/a.md\"}}" "a read inside the sandbox"
run '{"tool_name":"Read","tool_input":{"file_path":"x"}}' "/nonexistent/dir/log.jsonl" >/dev/null; [ $? = 2 ] && pass || fail "guard error (unwritable log) blocks with exit 2"
printf 'not json' | REPLAY_LOG="$d/log.jsonl" REPLAY_ROOTS="$d/sb" python3 "$g" >/dev/null 2>&1; [ $? = 2 ] && pass || fail "guard error (bad input) blocks with exit 2"
grep -q '"onFailure":"block"' "$HERE/replay.sh" && pass || fail "replay.sh wires the guard to block on a timeout or failure to start"
grep -q '"matcher":"\.\*"' "$HERE/replay.sh" && pass || fail "every tool call goes through the guard"
bash -n "$HERE/replay.sh" && pass || fail "replay.sh parses"

# --- The runner end to end, with a stand-in for the CLI (no model, no cost).
# The stand-in behaves like a session that tries to get out: it looks for the
# caller's home and environment, writes outside, plants a command in the
# snapshot's git configuration, and leaves a link where the runner reads a log.
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || { echo "(skip runner tests: no timeout)"; echo "replay: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]; exit; }
fh="$(mktemp -d "${HOME}/.replay-test.XXXXXX" 2>/dev/null)" || fh=""    # a stand-in home OUTSIDE /tmp, with a secret in it
[ -n "$fh" ] || { echo "(skip runner tests: cannot make a stand-in home)"; echo "replay: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]; exit; }
fh="$(cd "$fh" && pwd -P)"; echo TOPSECRET > "$fh/secret"; echo TOPSECRET > "$d/victim"
mkdir -p "$d/bin" "$d/plug/src" "$d/plug/set/one" "$d/plug"
# The sandbox runtime needs a ripgrep. The real CLI carries one; the stand-in below does not.
real="$(command -v claude 2>/dev/null || true)"
command -v rg >/dev/null 2>&1 || [ -z "$real" ] || { printf '#!/usr/bin/env bash\nexec -a rg %q "$@"\n' "$real" > "$d/bin/rg"; chmod +x "$d/bin/rg"; }
# A service of this machine, listening on its loopback address: the session must not reach it.
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(8); open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(300)' "$d/port" & lp=$!
i=0; until [ -s "$d/port" ] || [ $i -ge 50 ]; do sleep 0.1; i=$((i+1)); done; port="$(cat "$d/port")"
knock(){ python3 -c 'import socket,sys
try: socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2); print("open")
except OSError: print("closed")' "$1"; }
[ "$(knock "$port")" = open ] && pass || fail "the control: the listener answers on this machine"
cat > "$d/bin/claude" <<FAKE
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { echo "2.1.999 (Claude Code)"; exit 0; }
# Post-compaction mode: answer each turn, and after the first, rewrite the turn
# record the runner reads a line count from, with text a shell would evaluate.
case " \$* " in *" --input-format "*) n=0
  mkdir -p log; echo '{"event":"pc"}' >> log/journal.jsonl; [ -e hang ] && sleep 31.4159
  while IFS= read -r line; do n=\$((n+1))
    [ \$n = 2 ] && printf '{"_lines":{"j":"HOME[\$(touch %s)]"},"result":"r"}' "$d/escaped-arith" > "\$(dirname "\$REPLAY_LOG")/turn.1.json"
    echo '{"type":"result","result":"r"}'
  done; exit 0 ;; esac
cat >/dev/null
echo change > new.txt; mkdir -p log; echo '{"event":"x"}' >> log/journal.jsonl
mkdir -p keep/sub; echo kept > keep/sub/a.txt; ln -s "$d/victim" keep/link; ln -s "$d" keep/dirlink; ln -s "$d/victim" keeplink
[ -e hang ] && { sleep 31.4159 & sleep 31.4159; }
own=\$(cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep -q '^HOME=' && echo seen || echo blind)   # the control: /proc is readable
# The set, the source repo and the out dir all sit inside the plugin directory, which the session may read.
home=\$([ -e "$fh/secret" ] || [ -e "$d/plug/set/one/ask.md" ] || [ -e "$d/plug/src/a.txt" ] || [ -e "$d/plug/out/one.1/turn1.md" ] && echo seen || echo hidden)
canary=\$(cat /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | grep -c '^REPLAY_CANARY=')
touch "$d/escaped-write" 2>/dev/null
net=\$(python3 -c 'import socket
try: socket.create_connection(("127.0.0.1", $port), 2); print("open")
except OSError: print("closed")')
git config core.fsmonitor "sh -c 'touch $d/escaped-git' --"
# The same plant by a way the sandbox does not refuse: a second git directory the first one points at.
cp -R .git keep/alt 2>/dev/null && git config -f keep/alt/config core.fsmonitor "sh -c 'touch $d/escaped-git' --" && echo ../keep/alt > .git/commondir
ln -sf "$d/victim" "\$REPLAY_LOG" 2>/dev/null
printf '{"result":"home=%s canary=%s own=%s net=%s","num_turns":1,"duration_ms":1000,"total_cost_usd":0}\n' "\$home" "\$canary" "\$own" "\$net"
FAKE
chmod +x "$d/bin/claude"
( cd "$d/plug/src" && git init -q && git config user.email t@t && git config user.name t && mkdir log \
  && echo '{"event":"old"}' > log/journal.jsonl && echo a > a.txt && git add a.txt log/journal.jsonl && git commit -qm init ) >/dev/null 2>&1
git -C "$d/plug/src" rev-parse HEAD > "$d/plug/set/one/commit"; echo "an ask" > "$d/plug/set/one/ask.md"; echo note > "$d/plug/set/one/kind"; echo '{"result":"planted"}' > "$d/plug/set/one/compact.result.json"
rp(){ HOME="$fh" REPLAY_CANARY=leak ANTHROPIC_API_KEY=x PATH="$d/bin:$PATH" REPLAY_PLUGIN_DIR="$d/plug" REPLAY_PREFIX='/go ' \
        REPLAY_JOURNAL=log/journal.jsonl REPLAY_IGNORE=log/ REPLAY_KEEP="keep keeplink ../../etc" "$@" bash "$HERE/replay.sh" "$d/plug/set" "$d/plug/src" "$d/plug/out" 2>&1; }
o="$d/plug/out/one.1"
first="$(rp env)"
case "$first" in *'no usable sandbox runtime'*)
  pass   # without a sandbox the runner refuses unless told otherwise
  echo "(skip sandbox assertions: no usable sandbox runtime here)"
  [ "${CI:-}" != true ] || fail "CI must exercise the sandbox: the sandbox runtime is not usable on this runner ($(printf '%s' "$first" | head -n 2 | tr '\n' ' '))"
  rp env REPLAY_UNCONFINED=1 >/dev/null ;;
*)
  [ "$(cat "$o/say.md" 2>/dev/null)" = "home=hidden canary=0 own=seen net=closed" ] && pass \
    || fail "the sandbox hides the caller's home directory, environment and local services (got: $(cat "$o/say.md" 2>/dev/null))"
  [ ! -e "$d/escaped-write" ] && pass || fail "a write outside the sandbox does not reach the machine"
  [ ! -e "$d/escaped-git" ] && pass || fail "a command planted in the snapshot's git configuration does not run on the machine"
  # A session that hangs is ended by the time limit, and nothing it started survives.
  ( cd "$d/plug/src" && touch hang && git add hang && git commit -qm hang ) >/dev/null 2>&1
  git -C "$d/plug/src" rev-parse HEAD > "$d/plug/set/one/commit"
  rp env REPLAY_TIMEOUT=2 >/dev/null; sleep 1
  [ "$(cat "$o/say.md" 2>/dev/null)" = "(no result)" ] && pass || fail "the hung session was ended by the time limit (got: $(cat "$o/say.md" 2>/dev/null))"
  pgrep -f 'sleep 31\.4159' >/dev/null 2>&1 && fail "a timed-out session leaves processes running" || pass
  # An interrupted runner takes its sessions with it.
  rp env >/dev/null & rpid=$!; i=0
  until pgrep -f 'sleep 31\.4159' >/dev/null 2>&1 || [ $i -ge 50 ]; do sleep 0.2; i=$((i+1)); done
  pgrep -f 'sleep 31\.4159' >/dev/null 2>&1 && pass || fail "the session to interrupt started"
  pkill -TERM -f "replay.sh $d/plug/set" 2>/dev/null; wait "$rpid" 2>/dev/null; sleep 1
  pgrep -f 'sleep 31\.4159' >/dev/null 2>&1 && fail "an interrupted runner leaves its sessions running" || pass
  # Cut short in its first turn, a post-compaction run still shows what that turn journaled.
  rp env REPLAY_POSTCOMPACT=1 REPLAY_TIMEOUT=2 >/dev/null
  [ "$(cat "$o/journal.jsonl" 2>/dev/null)" = '{"event":"pc"}' ] && [ ! -s "$o/journal.turn2.jsonl" ] && pass \
    || fail "a run cut short in turn 1 keeps turn 1's journal rows (got: $(cat "$o/journal.jsonl" 2>/dev/null))"
  ( cd "$d/plug/src" && git rm -q hang && git commit -qm unhang ) >/dev/null 2>&1
  git -C "$d/plug/src" rev-parse HEAD > "$d/plug/set/one/commit"
  # Text the session wrote where the runner reads a number is never evaluated.
  rp env REPLAY_POSTCOMPACT=1 >/dev/null
  [ -f "$o/compact.result.json" ] && pass || fail "the post-compaction run produced its turns"
  [ ! -e "$d/escaped-arith" ] && [ ! -e /tmp/escaped-arith ] && pass || fail "a number field the session rewrote is not evaluated by the runner"
  # The one path the runtime shares with the machine must not exist when a replay starts.
  if [ ! -e /tmp/claude ] && mkdir /tmp/claude 2>/dev/null; then
    case "$(rp env)" in *'/tmp/claude exists'*) pass ;; *) fail "the runner refuses to start while /tmp/claude exists" ;; esac
    rmdir /tmp/claude
  fi
  rp env >/dev/null ;;
esac
grep -rq TOPSECRET "$d/plug/out" && fail "a link left by the session is not followed into the output" || pass
[ "$(cat "$o/keep/sub/a.txt" 2>/dev/null)" = kept ] && [ ! -e "$o/keep/link" ] && [ ! -e "$o/keep/dirlink" ] && [ ! -e "$o/keeplink" ] && [ ! -e "$o/etc" ] \
  && pass || fail "kept paths are copied as regular files only, from inside the snapshot only"
[ "$(cat "$o/turn1.md" 2>/dev/null)" = "/go an ask" ] && pass || fail "the prefix and the ask are sent verbatim"
[ "$(grep -v '^keep' "$o/changed-files.txt" 2>/dev/null)" = new.txt ] && pass || fail "changed files exclude run state (got: $(cat "$o/changed-files.txt" 2>/dev/null | tr '\n' ' '))"
[ "$(cat "$o/journal.jsonl" 2>/dev/null)" = '{"event":"x"}' ] && pass || fail "the journal keeps only this run's rows"
[ -f "$o/kind" ] && [ ! -f "$o/commit" ] && pass || fail "extra case files are copied out"
[ ! -e "$o/compact.result.json" ] && pass || fail "a case file named like an output does not stand in for it"
[ ! -e "$d/plug/src/new.txt" ] && [ -z "$(git -C "$d/plug/src" status --porcelain)" ] && pass || fail "the source repo is untouched"
echo stale > "$o/stale"; rp env REPLAY_UNCONFINED=1 >/dev/null; [ ! -e "$o/stale" ] && pass || fail "a rerun replaces the output directory"
kill "$lp" 2>/dev/null
echo "replay: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
