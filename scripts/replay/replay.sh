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
# session, 4; 8 in post-compaction mode), REPLAY_ALLOW_AGENTS (comma-separated
# read-only subagents that may really run; every other dispatch is recorded and
# refused), REPLAY_CARRY_SKILLS (space-separated names under ~/.claude/skills to
# copy into the sandbox), REPLAY_IGNORE (repo-relative prefix that is run state,
# not project work; default .agents/), REPLAY_JOURNAL (repo-relative path of an
# append-only log the plugin writes; its new rows are kept per turn),
# REPLAY_COLLECT (a command run as `<cmd> <sandbox-repo> <out> <plugin-dir>`
# after each session, to copy out whatever else a scorer needs).
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
# Safety. The session runs inside an OS sandbox (bubblewrap, Linux): the whole
# filesystem is read-only, the caller's home directory and per-user runtime
# directory are replaced by empty ones, it has its own process table (so no
# other process's environment is readable), and it can write only its snapshot,
# its throwaway HOME and its output directory. Its environment is built from
# nothing: HOME, PATH, TERM, LANG, TMPDIR and the model login. The snapshot is a
# `git archive` (tracked files only, no remote), taken with the caller's git
# configuration switched off so no filter, hook or signer of theirs runs.
# The network stays open, because the model is reached over it; the session
# holds no credential but the model login to use on it. That login is why
# guard.py refuses connected services by name. guard.py also refuses dispatches,
# the web, the network/cloud/credential commands it recognises and the outside
# paths it recognises, and refuses any tool it does not know. The guard is best
# effort (it pattern-matches commands), never the boundary; it is wired to block
# the tool when it errors, times out or cannot start ("onFailure": "block"),
# which needs Claude Code 2.1.295 or later, checked below.
# Without bubblewrap (macOS) there is no boundary, only the scrubbed environment
# and the guard: the session runs as you, can read your home directory by a
# path the guard does not recognise, and can read the environment of your other
# processes. The harness refuses to run that way unless REPLAY_UNCONFINED=1;
# use it only on a repository and a machine where that is acceptable.
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
BWRAP="$(command -v bwrap 2>/dev/null || true)"
[ -z "$BWRAP" ] || "$BWRAP" --ro-bind / / true 2>/dev/null || BWRAP=""   # present but not permitted here
[ -n "$BWRAP" ] || [ "${REPLAY_UNCONFINED:-}" = 1 ] || {
  echo "replay: no usable bubblewrap, so no sandbox boundary; set REPLAY_UNCONFINED=1 to run without one (see the header)" >&2; exit 2; }
[ -n "$BWRAP" ] || echo "replay: UNCONFINED: no sandbox boundary, only a scrubbed environment and a best-effort guard" >&2

MODEL="${REPLAY_MODEL:-opus}"; EFFORT="${REPLAY_EFFORT:-low}"; K="${REPLAY_K:-1}"
PDIR="$(cd "$REPLAY_PLUGIN_DIR" && pwd)"; JOBS="${REPLAY_JOBS:-4}"
PC="${REPLAY_POSTCOMPACT:-}"; [ "$PC" = 0 ] && PC=""
AFTER_DEFAULT="Continue. What is the state of this work and what is your next step?"
BUDGET="${REPLAY_BUDGET_USD:-$([ -n "$PC" ] && echo 8 || echo 4)}"; GUARD="$HERE/guard.py"
IGNORE="${REPLAY_IGNORE-.agents/}"; JOURNAL="${REPLAY_JOURNAL:-}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
[ $# -gt 0 ] && CASES="$*" || CASES="$(cd "$SET" && ls -d */ 2>/dev/null | tr -d /)"

# Every sandbox nests under one directory made here, in the parent shell, so one
# trap removes them all whichever subshell made them.
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/replay.XXXXXXXX")"; RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
trap 'cd /; rm -rf "$RUN_DIR"' EXIT
# An interrupt must stop the paid sessions too, so `timeout` runs them in this
# process group (--foreground) and the whole group is signalled.
trap 'trap "" INT TERM; kill 0 2>/dev/null; exit 130' INT TERM
REAL_HOME="$(cd "$HOME" && pwd -P)"
# The caller's git configuration (filters, hooks, signing) must not run on the snapshot.
cgit(){ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
mk_tmp(){ mktemp -d "$RUN_DIR/t.XXXXXXXX"; }

# The caller may itself be an agent session whose PATH carries an INSTALLED copy of
# the plugin's helpers; the replay must run the helpers of the plugin under test.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.claude/plugins/' -e '/plugins/[^/]*/bin$' | paste -sd: -)"

run_one(){ # <case> <k>
  local c="$1" k="$2" cd_="$SET/$1" o="$OUT/$1.$2" home repo commit s f turn1_end=""
  [ -f "$cd_/ask.md" ] && [ -f "$cd_/commit" ] || { echo "replay: $c lacks ask.md or commit" >&2; return; }
  commit="$(cgit -C "$SRC" rev-parse --verify --quiet --end-of-options "$(tr -d ' \n' < "$cd_/commit")^{commit}")" \
    || { echo "replay: $c: commit is not a commit of the source repo" >&2; return; }
  home="$(mk_tmp)"; repo="$(mk_tmp)"; rm -rf "$o"; mkdir -p "$o" "$home/.claude/skills" "$home/tmp"
  cgit -C "$SRC" archive "$commit" | tar -x -C "$repo" || { echo "replay: $c: cannot snapshot $commit" >&2; return; }
  # Project-level harness config can start servers and hooks of its own: drop it.
  rm -rf "$repo/.mcp.json" "$repo/.claude/settings.json" "$repo/.claude/settings.local.json" "$repo/.envrc"
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
    [ -d "$HOME/.claude/skills/$s" ] && cp -rL "$HOME/.claude/skills/$s" "$home/.claude/skills/" 2>/dev/null
  done
  cat > "$o/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"python3 '$GUARD'","timeout":10,"onFailure":"block"}]}]}}
JSON
  # The snapshot may carry a tracked copy of the journal; keep only what this run adds.
  local journal="${JOURNAL:+$repo/$JOURNAL}" base=0
  [ -n "$journal" ] && [ -f "$journal" ] && base="$(wc -l < "$journal" | tr -d ' ')"
  local cargs=(-p --model "$MODEL" --effort "$EFFORT" --plugin-dir "$PDIR" --settings "$o/settings.json"
               --max-budget-usd "$BUDGET" --allowedTools "Read,Grep,Glob,Write,Edit,Bash,Agent,Task,Skill")
  # The environment is built from nothing BEFORE the sandbox starts, so the
  # sandbox's own first process carries none of the caller's variables either.
  # /usr/bin/env, not `env`: an interactive caller's shell may define an `env` function.
  local box=()
  [ -z "$BWRAP" ] || box=("$BWRAP" --ro-bind / / --dev /dev --proc /proc --unshare-pid --unshare-ipc --die-with-parent
      --tmpfs "$REAL_HOME" --tmpfs "$RUN_DIR" --bind "$repo" "$repo" --bind "$home" "$home" --bind "$o" "$o"
      --ro-bind "$PDIR" "$PDIR" --ro-bind "$HERE" "$HERE" --ro-bind "$CLAUDE_BIN" "$CLAUDE_BIN" --chdir "$repo")
  [ -z "$BWRAP" ] || [ ! -d "/run/user/$(id -u)" ] || box+=(--tmpfs "/run/user/$(id -u)")
  session(){ ( cd "$repo" && /usr/bin/env -i \
      HOME="$home" PATH="$CLEAN_PATH" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" TMPDIR="$home/tmp" \
      ${ANTHROPIC_API_KEY:+ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
      ${CLAUDE_CODE_OAUTH_TOKEN:+CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"} \
      ${ANTHROPIC_DEFAULT_OPUS_MODEL:+ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL"} \
      REPLAY_ALLOW_AGENTS="${REPLAY_ALLOW_AGENTS:-}" REPLAY_LOG="$o/guard.jsonl" REPLAY_ROOTS="$repo:$home:$PDIR" \
      ${box[@]+"${box[@]}"} "$@" ); }
  { printf '%s' "${REPLAY_PREFIX:-}"; cat "$cd_/ask.md"; } > "$o/turn1.md"
  if [ -z "$PC" ]; then
    session timeout --foreground 900 "$CLAUDE_BIN" "${cargs[@]}" --output-format json < "$o/turn1.md" > "$o/result.json" 2> "$o/stderr.txt"
  else
    printf '/compact\n' > "$o/compact.md"
    if [ -f "$cd_/after.md" ]; then cp "$cd_/after.md" "$o/after.md"; else printf '%s\n' "$AFTER_DEFAULT" > "$o/after.md"; fi
    session timeout --foreground 2700 python3 "$HERE/turns.py" --split "$o/guard.jsonl" ${journal:+--lines "$journal"} \
        "$o/turn" "$o/turn1.md" "$o/compact.md" "$o/after.md" -- "$CLAUDE_BIN" "${cargs[@]}" > /dev/null 2> "$o/stderr.txt"
    mv "$o/turn.1.json" "$o/result.json" 2>/dev/null; mv "$o/turn.2.json" "$o/compact.result.json" 2>/dev/null
    mv "$o/turn.3.json" "$o/turn2.result.json" 2>/dev/null
    mv "$o/guard.jsonl.turn1" "$o/guard.jsonl" 2>/dev/null; mv "$o/guard.jsonl.turn2" "$o/guard.compact.jsonl" 2>/dev/null
    mv "$o/guard.jsonl.turn3" "$o/guard.turn2.jsonl" 2>/dev/null
    if [ -n "$journal" ]; then   # rows journaled after the compaction (turn 2 only)
      local after_compact
      after_compact="$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["_lines"].values())[0])' "$o/compact.result.json" 2>/dev/null || echo 0)"
      tail -n +"$(( after_compact + 1 ))" "$journal" > "$o/journal.turn2.jsonl" 2>/dev/null
      turn1_end="$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["_lines"].values())[0])' "$o/result.json" 2>/dev/null || echo "")"
    fi
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' "$o/turn2.result.json" > "$o/turn2.say.md" 2>/dev/null
  fi
  # In post-compaction mode this is turn 1 only, to match guard.jsonl.
  [ -n "$journal" ] && tail -n +"$(( base + 1 ))" "$journal" 2>/dev/null \
    | { [ -n "$turn1_end" ] && head -n "$(( turn1_end - base ))" || cat; } > "$o/journal.jsonl"
  cat "$home"/.claude/projects/*/*.jsonl > "$o/transcript.jsonl" 2>/dev/null
  # Everything the session changed since the snapshot, committed or not.
  ( cd "$repo" && { cgit diff --name-only "$(git rev-list --max-parents=0 HEAD | tail -1)" 2>/dev/null
      cgit ls-files --others --exclude-standard 2>/dev/null; } | awk -v p="$IGNORE" 'p == "" || index($0, p) != 1'  | sort -u ) > "$o/changed-files.txt"
  for f in "$cd_"/*; do case "${f##*/}" in commit|after.md) ;; *) [ -f "$f" ] && cp "$f" "$o/" ;; esac; done
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' "$o/result.json" > "$o/say.md" 2>/dev/null \
    || echo "(no result)" > "$o/say.md"
  [ -z "${REPLAY_COLLECT:-}" ] || $REPLAY_COLLECT "$repo" "$o" "$PDIR" || echo "replay: $c: collect command failed" >&2
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
done | tee -a "$OUT/summary.txt"
exit 0
