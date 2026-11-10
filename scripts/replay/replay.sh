#!/usr/bin/env bash
# Replay past asks through a plugin and keep what the session did, so an
# instruction change can be measured before and after on real asks. Works for
# any plugin in this repo; what "did the right thing" means is the caller's to
# score from the output (see README.md beside this file).
#
#   bash scripts/replay/replay.sh <set-dir> <source-repo> <out-dir> [case ...]
#
# A set is a directory of cases, one directory each, kept OUTSIDE this repo
# (real asks name real systems):
#   <case>/ask.md    the ask, verbatim
#   <case>/commit    the source-repo commit the ask was made against
#   <case>/after.md  optional: the follow-up turn in post-compaction mode
#   anything else    copied to the output as is (a kind, an answer key)
#
# Env, required: REPLAY_PLUGIN_DIR (the plugin under test, a working tree).
# Env, optional: REPLAY_PREFIX (text sent before the ask, such as a slash
# command and a space), REPLAY_MODEL (opus), REPLAY_EFFORT (low), REPLAY_K (runs
# per case, 1), REPLAY_JOBS (parallel sessions, 4), REPLAY_BUDGET_USD (per
# session, 4; 8 in post-compaction mode), REPLAY_TIMEOUT (seconds per session,
# 900; 2700 in post-compaction mode), REPLAY_ALLOW_AGENTS (comma-separated
# read-only subagents that may really run; every other dispatch is recorded and
# refused), REPLAY_CARRY_SKILLS (space-separated names under ~/.claude/skills to
# copy into the sandbox), REPLAY_IGNORE (repo-relative prefix that is run state,
# not project work; default .agents/), REPLAY_JOURNAL (repo-relative path of an
# append-only log the plugin writes; its new rows are kept per turn),
# REPLAY_KEEP (space-separated repo-relative paths to copy out after each
# session, each to <out>/<its last name>; regular files only, links never
# followed).
#
# An existing <out-dir>/<case>.<k> is replaced, never added to.
#
# Post-compaction mode, REPLAY_POSTCOMPACT=1: one process runs three turns
# (turns.py): the ask, then `/compact`, then after.md (default below).
#
# Output, per run, in <out-dir>/<case>.<k>/:
#   turn1.md result.json say.md   what was sent, the result event, the closing message
#   guard.jsonl                   every tool call the guard judged, allowed or refused
#   transcript.jsonl              the session transcript
#   changed-files.txt             project files the session changed
#   journal.jsonl                 rows added to REPLAY_JOURNAL
#   post-compaction mode adds compact.result.json, guard.compact.jsonl,
#   turn2.result.json, turn2.say.md, guard.turn2.jsonl, journal.turn2.jsonl,
#   turn.stream.jsonl, compact.md, after.md; journal.jsonl then holds turn 1 only
#   settings.json stderr.txt      the hook wiring used, and the CLI's stderr
# and <out-dir>/summary.txt, one line per run.
#
# Safety. On Linux each session runs inside an OS sandbox (bubblewrap):
#   - the filesystem is read-only, and these are replaced by empty directories:
#     the caller's home, /tmp, /var/tmp, TMPDIR, /run (sockets of the caller's
#     other programs live there), the source repo, the set and the out dir;
#   - it has its own process table, so no other process's environment is
#     readable, and an environment built from nothing: HOME, PATH, TERM, LANG,
#     TMPDIR and the model login;
#   - it can write only its snapshot, its throwaway HOME and a log directory.
#     It never sees the out dir. The runner copies results there itself, never
#     following a link the session left, and runs git on the snapshot only
#     inside the sandbox, because the snapshot's git configuration is the
#     session's to edit;
#   - with pasta present it has a network of its own, so services bound to
#     this machine's loopback address are out of reach. Without pasta the
#     runner says so and the session shares the machine's network. Either way,
#     services bound to another address of this machine (a container bridge, a
#     VPN address) and the name resolver's socket stay reachable;
#   - the time limit runs inside the sandbox, so nothing a session started
#     outlives it.
# The snapshot is a `git archive` (tracked files only, no remote), taken with
# the caller's git configuration switched off so no filter, hook or signer of
# theirs runs.
# What the sandbox does not cover: the internet stays reachable, because the
# model is reached over it, and the session holds the model login. guard.py is
# what refuses the web and the connected services that come with that login
# (they are also switched off by ENABLE_CLAUDEAI_MCP_SERVERS=false); it refuses
# dispatches and any tool it does not know as well. The guard is best effort (it
# pattern-matches commands), never the boundary. It blocks the tool when it
# errors, times out or cannot start, which needs Claude Code 2.1.295 or later,
# checked below. A session that got past the guard could send what it can read
# (the snapshot, the plugin, the operator's CLAUDE.md) anywhere on the internet.
# Tools installed under the caller's home are not on the session's PATH.
# Without a usable bubblewrap (macOS, some containers) there is no boundary,
# only the scrubbed environment and the guard: the session runs as you. The
# runner refuses to start that way unless REPLAY_UNCONFINED=1.
#
# Claude Code only: Codex and OpenCode would each need their own driver.
# Reporting only; never a CI gate. Self-skips without claude/auth/python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SET="${1:?set dir}"; SRC="${2:?source repo}"; OUT="${3:?out dir}"; shift 3
command -v claude >/dev/null 2>&1 || { echo "(skip replay: claude not on PATH)"; exit 0; }
# Only logins the sandboxed session can be handed: a key, a token, or the credential file.
[ -n "${ANTHROPIC_API_KEY:-}" ] || [ -f "$HOME/.claude/.credentials.json" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
  || { echo "(skip replay: no live auth)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "(skip replay: python3 absent)"; exit 0; }
[ "$(df -Pk "${TMPDIR:-/tmp}" | awk 'NR==2{print $4}')" -ge 1048576 ] || { echo "(skip replay: low tmp space)"; exit 0; }
[ -d "$SET" ] && git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || { echo "replay: need a set dir and a git source repo" >&2; exit 2; }
[ -d "${REPLAY_PLUGIN_DIR:-}" ] || { echo "replay: set REPLAY_PLUGIN_DIR to the plugin under test" >&2; exit 2; }
# The guard only blocks on its own failure from 2.1.295 on; an older CLI would run the tool.
ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$(printf '%s\n' 2.1.295 "${ver:-0}" | sort -V | head -1)" = 2.1.295 ] \
  || { echo "replay: needs Claude Code 2.1.295 or later (found ${ver:-none})" >&2; exit 2; }
CLAUDE_BIN="$(readlink -f "$(command -v claude)" 2>/dev/null || command -v claude)"
TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$TIMEOUT" ] || { echo "replay: needs timeout (GNU coreutils)" >&2; exit 2; }
REAL_HOME="$(cd "$HOME" 2>/dev/null && pwd -P)"
[ -n "$REAL_HOME" ] || { echo "replay: HOME is not a directory" >&2; exit 2; }
SRC="$(cd "$SRC" && pwd -P)"; SET="$(cd "$SET" && pwd -P)"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"
[ -n "$OUT" ] || { echo "replay: cannot use the out dir" >&2; exit 2; }
case "$HERE$OUT" in *\'*|*\"*) echo "replay: a quote character in the harness or out dir path is not supported" >&2; exit 2 ;; esac

# The sandbox, probed with the flags the sessions use: a tool that is present
# but not permitted here (a container, a restricted runner) counts as absent.
BOX_BASE=(--ro-bind / / --dev /dev --proc /proc --unshare-pid --unshare-ipc --new-session --die-with-parent --tmpfs /tmp)
BWRAP="$(command -v bwrap 2>/dev/null || true)"
[ -z "$BWRAP" ] || "$BWRAP" "${BOX_BASE[@]}" true 2>/dev/null || BWRAP=""
[ -n "$BWRAP" ] || [ "${REPLAY_UNCONFINED:-}" = 1 ] || {
  echo "replay: no usable bubblewrap, so no sandbox boundary; set REPLAY_UNCONFINED=1 to run without one (see the header)" >&2; exit 2; }
[ -n "$BWRAP" ] || echo "replay: UNCONFINED: no sandbox boundary, only a scrubbed environment and a best-effort guard" >&2
# A network of its own (user-mode, via pasta) keeps this machine's local
# services and abstract sockets out of reach while the model stays reachable.
NET=(); PASTA="$(command -v pasta 2>/dev/null || true)"
if [ -n "$BWRAP" ] && [ -n "$PASTA" ] && "$PASTA" --config-net --no-map-gw -t none -u none -T none -U none -- true >/dev/null 2>&1; then
  NET=("$PASTA" --config-net --no-map-gw -t none -u none -T none -U none --)
elif [ -n "$BWRAP" ]; then
  echo "replay: no usable pasta: sessions share this machine's network, so its local services stay reachable" >&2
fi

MODEL="${REPLAY_MODEL:-opus}"; EFFORT="${REPLAY_EFFORT:-low}"; K="${REPLAY_K:-1}"
PDIR="$(cd "$REPLAY_PLUGIN_DIR" && pwd -P)"; JOBS="${REPLAY_JOBS:-4}"
PC="${REPLAY_POSTCOMPACT:-}"; [ "$PC" = 0 ] && PC=""
AFTER_DEFAULT="Continue. What is the state of this work and what is your next step?"
BUDGET="${REPLAY_BUDGET_USD:-$([ -n "$PC" ] && echo 8 || echo 4)}"; GUARD="$HERE/guard.py"
LIMIT="${REPLAY_TIMEOUT:-$([ -n "$PC" ] && echo 2700 || echo 900)}"
IGNORE="${REPLAY_IGNORE-.agents/}"; JOURNAL="${REPLAY_JOURNAL:-}"
# The set and the out dir are hidden from the session last, on top of everything
# else, so nothing the session needs may sit inside them.
for d in "$PDIR" "$HERE" "$CLAUDE_BIN" "$(cd "${TMPDIR:-/tmp}" && pwd -P)"; do case "$d/" in "$OUT"/*|"$SET"/*)
  echo "replay: the set and the out dir must not contain the plugin, the harness, the CLI or TMPDIR ($d)" >&2; exit 2 ;; esac; done
[ $# -gt 0 ] && CASES="$*" || CASES="$(cd "$SET" && ls -d */ 2>/dev/null | tr -d /)"

# Every sandbox nests under one directory made here, in the parent shell, so one
# trap removes them all whichever subshell made them.
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/replay.XXXXXXXX")" || exit 2
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
trap 'cd /; [ -n "$RUN_DIR" ] && rm -rf "$RUN_DIR"' EXIT
# An interrupt must stop the paid sessions too: the whole process group is
# signalled, and a sandbox dies with the process that started it. The time limit
# runs INSIDE the sandbox, as its first process: when it ends the session, the
# sandbox ends with it and nothing the session started survives.
trap 'trap "" INT TERM; kill 0 2>/dev/null; exit 130' INT
trap 'trap "" INT TERM; kill 0 2>/dev/null; exit 143' TERM
# The caller's git configuration (filters, hooks, signing) must not run on the snapshot.
cgit(){ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
mk_tmp(){ mktemp -d "$RUN_DIR/t.XXXXXXXX"; }
# Read a file the session could have written, only if it is a regular file that
# really lives under <root>: the session may have left a link pointing elsewhere.
# take copies it to <dest> (and writes nothing when it is not there); emit prints it.
real_under(){ # <root> <file> -> prints the real path, or fails
  local real; real="$(readlink -f "$2" 2>/dev/null)" || return 1
  case "$real" in "$1"/*) [ -f "$real" ] && printf '%s\n' "$real" ;; *) return 1 ;; esac; }
emit(){ local r; r="$(real_under "$1" "$2")" && cat "$r"; }
take(){ local r; r="$(real_under "$1" "$2")" && cat "$r" > "$3"; }
jget(){ python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));print(list(v["_lines"].values())[0] if sys.argv[2]=="_lines" else v.get("result",""))' "$1" "$2" 2>/dev/null; }

# The caller may itself be an agent session whose PATH carries an INSTALLED copy of
# the plugin's helpers; the replay must run the helpers of the plugin under test.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.claude/plugins/' -e '/plugins/[^/]*/bin$' | paste -sd: -)"

run_one(){ # <case> <k>
  local c="$1" k="$2" cd_="$SET/$1" o="$OUT/$1.$2" home repo log cfg commit s f d n turn1_end=""
  [ -f "$cd_/ask.md" ] && [ -f "$cd_/commit" ] || { echo "replay: $c lacks ask.md or commit" >&2; return; }
  commit="$(cgit -C "$SRC" rev-parse --verify --quiet --end-of-options "$(tr -d ' \n' < "$cd_/commit")^{commit}")" \
    || { echo "replay: $c: commit is not a commit of the source repo" >&2; return; }
  # Four directories per run. The session can write its snapshot, its HOME and
  # its log directory; it can only read cfg. The output directory is the
  # caller's: the session never sees it, and nothing in it is written by it.
  home="$(mk_tmp)"; repo="$(mk_tmp)"; log="$(mk_tmp)"; cfg="$(mk_tmp)"
  rm -rf "${OUT:?}/$c.$k"; mkdir -p "$o" "$home/.claude/skills" "$home/tmp"
  cgit -C "$SRC" archive "$commit" | tar -x -C "$repo" || { echo "replay: $c: cannot snapshot $commit" >&2; return; }
  # Project-level harness config can start servers and hooks of its own: drop it.
  ( cd "$repo" && { [ ! -L .claude ] || rm -f .claude; } && rm -rf .mcp.json .claude/settings.json .claude/settings.local.json .envrc )
  ( cd "$repo" && cgit init -q && git config user.email t@t && git config user.name t \
      && { [ -z "$IGNORE" ] || printf '%s\n' "$IGNORE" >> .git/info/exclude; } \
      && cgit add --all >/dev/null 2>&1 && cgit commit -qm snapshot ) \
    || { echo "replay: $c: cannot commit the snapshot" >&2; return; }
  # Only the model login, the operator's standing preferences (they shape how a
  # session asks) and the named skills are carried into the sandbox HOME.
  for f in .credentials.json CLAUDE.md; do
    [ -f "$HOME/.claude/$f" ] && cp -L "$HOME/.claude/$f" "$home/.claude/$f" 2>/dev/null
  done
  for s in ${REPLAY_CARRY_SKILLS:-}; do
    [ -d "$HOME/.claude/skills/$s" ] && cp -RL "$HOME/.claude/skills/$s" "$home/.claude/skills/" 2>/dev/null
  done
  # The hook wiring is read-only to the session, and so is its user settings
  # file, so it cannot unhook the guard from there.
  echo '{}' > "$home/.claude/settings.json"
  cat > "$cfg/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"python3 '$GUARD'","timeout":10,"onFailure":"block"}]}]}}
JSON
  cp "$cfg/settings.json" "$o/settings.json"
  # The snapshot may carry a tracked copy of the journal; keep only what this run adds.
  local journal="${JOURNAL:+$repo/$JOURNAL}" base=0
  [ -n "$journal" ] && [ -f "$journal" ] && base="$(wc -l < "$journal" | tr -d ' ')"
  local cargs=(-p --model "$MODEL" --effort "$EFFORT" --plugin-dir "$PDIR" --settings "$cfg/settings.json"
               --max-budget-usd "$BUDGET" --allowedTools "Read,Grep,Glob,Write,Edit,Bash,Agent,Task,Skill")
  # Mount order matters: the empty directories first, then what is put back on top.
  local box=()
  if [ -n "$BWRAP" ]; then
    box=(${NET[@]+"${NET[@]}"} "$BWRAP" "${BOX_BASE[@]}")
    for d in /var/tmp /run "$REAL_HOME" "$(cd "${TMPDIR:-/tmp}" && pwd -P)" "$SRC"; do
      [ -d "$d" ] && box+=(--tmpfs "$d")
    done
    d="$(dirname "$(readlink -f /etc/resolv.conf 2>/dev/null)")"          # name resolution may live under /run
    case "$d" in /run/*) box+=(--ro-bind "$d" "$d") ;; esac
    box+=(--bind "$repo" "$repo" --bind "$home" "$home" --bind "$log" "$log" --ro-bind "$cfg" "$cfg"
          --ro-bind "$home/.claude/settings.json" "$home/.claude/settings.json"
          --ro-bind "$PDIR" "$PDIR" --ro-bind "$HERE" "$HERE" --ro-bind "$CLAUDE_BIN" "$CLAUDE_BIN"
          --tmpfs "$SET" --tmpfs "$OUT" --chdir "$repo")
  fi
  # The environment is built from nothing BEFORE the sandbox starts, so the
  # sandbox's own first process carries none of the caller's variables either.
  # /usr/bin/env, not `env`: an interactive caller's shell may define an `env` function.
  inbox(){ ( cd "$repo" && /usr/bin/env -i HOME="$home" PATH="$CLEAN_PATH" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" \
      TMPDIR="$home/tmp" "$@" ); }
  session(){ inbox ENABLE_CLAUDEAI_MCP_SERVERS=false \
      ${ANTHROPIC_API_KEY:+ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
      ${CLAUDE_CODE_OAUTH_TOKEN:+CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"} \
      ${ANTHROPIC_DEFAULT_OPUS_MODEL:+ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL"} \
      REPLAY_ALLOW_AGENTS="${REPLAY_ALLOW_AGENTS:-}" REPLAY_LOG="$log/guard.jsonl" REPLAY_ROOTS="$repo:$home:$PDIR" \
      ${box[@]+"${box[@]}"} "$TIMEOUT" -k 10 "$1" "${@:2}"; }
  { printf '%s' "${REPLAY_PREFIX:-}"; cat "$cd_/ask.md"; } > "$log/turn1.md"; cp "$log/turn1.md" "$o/turn1.md"
  if [ -z "$PC" ]; then
    session "$LIMIT" "$CLAUDE_BIN" "${cargs[@]}" --output-format json < "$o/turn1.md" > "$o/result.json" 2> "$o/stderr.txt"
    take "$log" "$log/guard.jsonl" "$o/guard.jsonl"
  else
    printf '/compact\n' > "$log/compact.md"
    if [ -f "$cd_/after.md" ]; then cp "$cd_/after.md" "$log/after.md"; else printf '%s\n' "$AFTER_DEFAULT" > "$log/after.md"; fi
    cp "$log/compact.md" "$log/after.md" "$o/"
    session "$LIMIT" python3 "$HERE/turns.py" --split "$log/guard.jsonl" ${journal:+--lines "$journal"} \
        "$log/turn" "$log/turn1.md" "$log/compact.md" "$log/after.md" -- "$CLAUDE_BIN" "${cargs[@]}" > /dev/null 2> "$o/stderr.txt"
    # <file the session side wrote>:<its name in the output>
    for f in turn.1.json:result.json turn.2.json:compact.result.json turn.3.json:turn2.result.json turn.stream.jsonl:turn.stream.jsonl \
             guard.jsonl.turn1:guard.jsonl guard.jsonl.turn2:guard.compact.jsonl guard.jsonl.turn3:guard.turn2.jsonl; do
      take "$log" "$log/${f%%:*}" "$o/${f##*:}"
    done
    turn1_end="$(jget "$o/result.json" _lines)"
    jget "$o/turn2.result.json" result > "$o/turn2.say.md"
  fi
  if [ -n "$journal" ]; then
    # In post-compaction mode journal.jsonl is turn 1 only, to match guard.jsonl,
    # and journal.turn2.jsonl is what was added after the compaction.
    n=$(( ${turn1_end:-0} - base )); [ "$n" -gt 0 ] || n=0
    emit "$repo" "$journal" | tail -n +"$(( base + 1 ))" | { [ -n "$PC" ] && head -n "$n" || cat; } > "$o/journal.jsonl"
    [ -z "$PC" ] || emit "$repo" "$journal" | tail -n +"$(( $(jget "$o/compact.result.json" _lines || echo 0) + 1 ))" > "$o/journal.turn2.jsonl"
  fi
  for f in "$home"/.claude/projects/*/*.jsonl; do emit "$home" "$f"; done > "$o/transcript.jsonl" 2>/dev/null
  # Everything the session changed since the snapshot, committed or not. The
  # repo's git configuration is now the session's, so git runs inside the sandbox.
  inbox ${box[@]+"${box[@]}"} "$TIMEOUT" -k 5 60 sh -c 'git diff --name-only "$(git rev-list --max-parents=0 HEAD | tail -1)"; git ls-files --others --exclude-standard' 2>/dev/null \
    | awk -v p="$IGNORE" 'p == "" || index($0, p) != 1' | sort -u > "$o/changed-files.txt"
  for f in "$cd_"/*; do case "${f##*/}" in commit|after.md) ;; *) [ -f "$f" ] && cp "$f" "$o/" ;; esac; done
  jget "$o/result.json" result > "$o/say.md" || echo "(no result)" > "$o/say.md"
  # Copied by the runner as the caller, from files the session wrote: regular
  # files only, no link followed anywhere on the way, nothing large.
  python3 - "$repo" "$o" ${REPLAY_KEEP:-} <<'KEEP'
import os, shutil, stat, sys
repo, out = os.path.realpath(sys.argv[1]), sys.argv[2]
def ok(p):   # a regular file whose real path is itself: no link in any component
    try: st = os.lstat(p)
    except OSError: return False
    return stat.S_ISREG(st.st_mode) and st.st_size <= 5 << 20 and os.path.realpath(p) == p
for rel in sys.argv[3:]:
    src = os.path.normpath(os.path.join(repo, rel)); dst = os.path.join(out, os.path.basename(src))
    if not src.startswith(repo + os.sep) or os.path.realpath(src) != src: continue
    if ok(src): shutil.copyfile(src, dst, follow_symlinks=False); continue
    for top, dirs, files in os.walk(src, followlinks=False):
        for f in files:
            p = os.path.join(top, f)
            if ok(p):
                t = os.path.join(dst, os.path.relpath(p, src)); os.makedirs(os.path.dirname(t), exist_ok=True)
                shutil.copyfile(p, t, follow_symlinks=False)
KEEP
}

n=0
for c in $CASES; do for k in $(seq 1 "$K"); do
  run_one "$c" "$k" & n=$((n+1)); [ $((n % JOBS)) -eq 0 ] && wait
done; done; wait

# One line per run from what every plugin has: refused = tool calls the guard
# refused, edits = project files changed, then the cost of the first turn.
printf '%-28s %-7s %-5s %-5s %-5s %s\n' run refused edits turns secs cost | tee "$OUT/summary.txt"
for o in "$OUT"/*/; do python3 - "${o%/}" <<'PY'
import json, os, sys
o = sys.argv[1]
def n(p, keep=lambda l: l.strip()):
    try: return sum(1 for l in open(p) if keep(l))
    except Exception: return 0
try: r = json.load(open(o + "/result.json"))
except Exception: r = {}
print("%-28s %-7d %-5d %-5s %-5s %s" % (os.path.basename(o), n(o + "/guard.jsonl", lambda l: '"decision": "deny"' in l),
      n(o + "/changed-files.txt"), r.get("num_turns", "-"), int(r.get("duration_ms", 0) / 1000) or "-",
      ("%.2f" % r["total_cost_usd"]) if "total_cost_usd" in r else "-"))
PY
done | LC_ALL=C tr -cd '[:print:]\n' | tee -a "$OUT/summary.txt"   # session-written text never reaches the terminal raw
exit 0
