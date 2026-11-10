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
#   turn.stream.jsonl
# and <out-dir>/summary.txt, one line per run.
#
# Safety: what keeps a replay harmless is that the session has nothing to misuse.
# It runs on a `git archive` snapshot (tracked files only, no remote) with a
# throwaway HOME and a scrubbed environment (no inherited cloud, vault, SSH or
# git-remote credentials). On top of that, guard.py refuses dispatches,
# connected services and the web, the network/cloud/credential commands it
# recognises, and the paths outside the sandbox it recognises. The guard is
# best effort (it pattern-matches commands), never the boundary. It is wired to
# block the tool when it errors, times out or cannot start ("onFailure": "block",
# Claude Code 2.1.295 or later; an older CLI runs the tool on a guard failure).
# PATH is the caller's (minus installed plugin bins), so tools stay reachable;
# that a vault or cloud CLI cannot authenticate without the inherited environment
# is assumed, not verified. The sandbox HOME does carry the model account's
# login, which is why connected services are refused by name.
#
# Claude Code only: Codex and OpenCode would each need their own driver.
# Reporting only; never a CI gate. Self-skips without claude/auth/python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SET="${1:?set dir}"; SRC="${2:?source repo}"; OUT="${3:?out dir}"; shift 3
command -v claude >/dev/null 2>&1 || { echo "(skip replay: claude not on PATH)"; exit 0; }
[ -n "${ANTHROPIC_API_KEY:-}" ] || [ -f "$HOME/.claude/.credentials.json" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
  || [ -n "${CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR:-}" ] || { echo "(skip replay: no live auth)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "(skip replay: python3 absent)"; exit 0; }
[ "$(df -Pk "${TMPDIR:-/tmp}" | awk 'NR==2{print $4}')" -ge 1048576 ] || { echo "(skip replay: low tmp space)"; exit 0; }
[ -d "$SET" ] && [ -d "$SRC/.git" ] || { echo "replay: need a set dir and a git source repo" >&2; exit 2; }
[ -d "${REPLAY_PLUGIN_DIR:-}" ] || { echo "replay: set REPLAY_PLUGIN_DIR to the plugin under test" >&2; exit 2; }

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
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/replay.XXXXXXXX")"; trap 'cd /; rm -rf "$RUN_DIR"' EXIT
mk_tmp(){ mktemp -d "$RUN_DIR/t.XXXXXXXX"; }

# The caller may itself be an agent session whose PATH carries an INSTALLED copy of
# the plugin's helpers; the replay must run the helpers of the plugin under test.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.claude/plugins/' -e '/plugins/[^/]*/bin$' | paste -sd: -)"

run_one(){ # <case> <k>
  local c="$1" k="$2" cd_="$SET/$1" o="$OUT/$1.$2" home repo commit s f
  [ -f "$cd_/ask.md" ] && [ -f "$cd_/commit" ] || { echo "replay: $c lacks ask.md or commit" >&2; return; }
  commit="$(tr -d ' \n' < "$cd_/commit")"; home="$(mk_tmp)"; repo="$(mk_tmp)"; mkdir -p "$o" "$home/.claude/skills"
  git -C "$SRC" archive "$commit" | tar -x -C "$repo" || { echo "replay: $c: cannot snapshot $commit" >&2; return; }
  # Project-level harness config can start servers and hooks of its own: drop it.
  rm -rf "$repo/.mcp.json" "$repo/.claude/settings.json" "$repo/.claude/settings.local.json" "$repo/.envrc"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && { [ -z "$IGNORE" ] || printf '%s\n' "$IGNORE" >> .git/info/exclude; } \
      && git add -A >/dev/null 2>&1 && git commit -qm snapshot )
  # Only the model login, the operator's standing preferences (they shape how a
  # session asks) and the named skills are carried into the sandbox HOME.
  for f in .credentials.json CLAUDE.md; do
    [ -f "$HOME/.claude/$f" ] && cp -L "$HOME/.claude/$f" "$home/.claude/$f" 2>/dev/null
  done
  for s in ${REPLAY_CARRY_SKILLS:-}; do
    [ -d "$HOME/.claude/skills/$s" ] && cp -rL "$HOME/.claude/skills/$s" "$home/.claude/skills/" 2>/dev/null
  done
  cat > "$o/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Agent|Task|Bash|Read|Write|Edit|Glob|Grep|NotebookEdit|WebFetch|WebSearch|mcp__.*","hooks":[{"type":"command","command":"python3 $GUARD","timeout":10,"onFailure":"block"}]}]}}
JSON
  # The snapshot may carry a tracked copy of the journal; keep only what this run adds.
  local journal="${JOURNAL:+$repo/$JOURNAL}" base=0
  [ -n "$journal" ] && [ -f "$journal" ] && base="$(wc -l < "$journal" | tr -d ' ')"
  local cargs=(-p --model "$MODEL" --effort "$EFFORT" --plugin-dir "$PDIR" --settings "$o/settings.json"
               --max-budget-usd "$BUDGET" --allowedTools "Read,Grep,Glob,Write,Edit,Bash,Agent,Task,Skill")
  # /usr/bin/env, not `env`: an interactive caller's shell may define an `env` function.
  session(){ ( cd "$repo" && /usr/bin/env -i \
      HOME="$home" PATH="$CLEAN_PATH" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
      ${ANTHROPIC_API_KEY:+ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
      ${ANTHROPIC_DEFAULT_OPUS_MODEL:+ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL"} \
      REPLAY_ALLOW_AGENTS="${REPLAY_ALLOW_AGENTS:-}" REPLAY_LOG="$o/guard.jsonl" REPLAY_ROOTS="$repo:$home:$PDIR:$RUN_DIR" \
      "$@" ); }
  { printf '%s' "${REPLAY_PREFIX:-}"; cat "$cd_/ask.md"; } > "$o/turn1.md"
  if [ -z "$PC" ]; then
    session timeout 900 claude "${cargs[@]}" --output-format json < "$o/turn1.md" > "$o/result.json" 2> "$o/stderr.txt"
  else
    printf '/compact\n' > "$o/compact.md"
    if [ -f "$cd_/after.md" ]; then cp "$cd_/after.md" "$o/after.md"; else printf '%s\n' "$AFTER_DEFAULT" > "$o/after.md"; fi
    session timeout 2700 python3 "$HERE/turns.py" --split "$o/guard.jsonl" ${journal:+--lines "$journal"} \
        "$o/turn" "$o/turn1.md" "$o/compact.md" "$o/after.md" -- claude "${cargs[@]}" > /dev/null 2> "$o/stderr.txt"
    mv "$o/turn.1.json" "$o/result.json" 2>/dev/null; mv "$o/turn.2.json" "$o/compact.result.json" 2>/dev/null
    mv "$o/turn.3.json" "$o/turn2.result.json" 2>/dev/null
    mv "$o/guard.jsonl.turn1" "$o/guard.jsonl" 2>/dev/null; mv "$o/guard.jsonl.turn2" "$o/guard.compact.jsonl" 2>/dev/null
    mv "$o/guard.jsonl.turn3" "$o/guard.turn2.jsonl" 2>/dev/null
    if [ -n "$journal" ]; then   # rows journaled after the compaction (turn 2 only)
      local after_compact
      after_compact="$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["_lines"].values())[0])' "$o/compact.result.json" 2>/dev/null || echo 0)"
      tail -n +"$(( after_compact + 1 ))" "$journal" > "$o/journal.turn2.jsonl" 2>/dev/null
    fi
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' "$o/turn2.result.json" > "$o/turn2.say.md" 2>/dev/null
  fi
  [ -n "$journal" ] && tail -n +"$(( base + 1 ))" "$journal" > "$o/journal.jsonl" 2>/dev/null
  cat "$home"/.claude/projects/*/*.jsonl > "$o/transcript.jsonl" 2>/dev/null
  # Everything the session changed since the snapshot, committed or not.
  ( cd "$repo" && { git diff --name-only "$(git rev-list --max-parents=0 HEAD | tail -1)" 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null; } | awk -v p="$IGNORE" 'p == "" || index($0, p) != 1'  | sort -u ) > "$o/changed-files.txt"
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
