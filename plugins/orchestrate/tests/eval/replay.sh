#!/usr/bin/env bash
# Tier 3c, replay: run past opening asks through the router and record what it
# does BEFORE any work starts. The before/after measure for intake changes
# (clarify, sizing): did the router ask, and what, or did it start dispatching?
#
#   bash tests/eval/replay.sh <set-dir> <source-repo> <out-dir> [case ...]
#
# A set is a directory of cases, one directory each, kept OUTSIDE this repo
# (real asks name real systems):
#   <case>/ask.md    the ask as it reached intake, verbatim
#   <case>/commit    the source-repo commit the ask was made against
#   <case>/kind      big | control   (a control must draw no question)
#   <case>/key.md    optional: what later changed, for whoever grades the run
#
# Env: REPLAY_MODEL (default opus), REPLAY_EFFORT (default low), REPLAY_K
# (runs per case, default 1), REPLAY_PLUGIN_DIR (plugin under test; default
# this checkout), REPLAY_JOBS (parallel sessions, default 4), REPLAY_BUDGET_USD
# (per session, default 4), REPLAY_ALLOW_AGENTS (comma-separated read-only
# personas that may really run; every other dispatch is recorded and refused).
#
# Post-compaction mode, REPLAY_POSTCOMPACT=1: does the router still hold and
# follow its instructions after a compaction? One process runs three turns
# (replay-turns.py): the start command with the ask (as above), then `/compact`,
# then the line in the optional <case>/after.md (default below). Per-turn output:
# result.json + guard.jsonl (turn 1, so the scorecard line still means "before
# any work"), compact.result.json + guard.compact.jsonl, turn2.result.json +
# guard.turn2.jsonl + board.turn2.jsonl + turn2.say.md; skill.md is the router
# brief under test. replay-postcompact-score.py prints the second scorecard.
# The budget covers all three turns (default 8 in this mode).
#
# Safety: what keeps a replay harmless is that the session has nothing to misuse.
# It runs on a `git archive` snapshot (tracked files only, no remote) with a
# throwaway HOME and a scrubbed environment (no inherited cloud, vault, SSH or
# git-remote credentials). On top of that, replay-guard.py refuses dispatches,
# connected services and the web, the network/cloud/credential commands it
# recognises, and the paths outside the sandbox it recognises. The guard is
# best effort (it pattern-matches commands), never the boundary. The sandbox
# HOME does carry the model account's login, which is why connected services
# are refused by name.
# The headless session has no human: a router that wants to ask can only
# journal the ask and say it. That is the signal.
#
# Reporting only; never a CI gate. Self-skips without claude/auth/python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INT_HERE="$HERE/../integration"; export INT_HERE
. "$INT_HERE/lib.sh"

SET="${1:?set dir}"; SRC="${2:?source repo}"; OUT="${3:?out dir}"; shift 3
have_claude    || { echo "(skip replay: claude not on PATH)"; exit 0; }
have_live_auth || { echo "(skip replay: no live auth)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "(skip replay: python3 absent)"; exit 0; }
int_space_ok   || { echo "(skip replay: low tmp space)"; exit 0; }
[ -d "$SET" ] && [ -d "$SRC/.git" ] || { echo "replay: need a set dir and a git source repo" >&2; exit 2; }

MODEL="${REPLAY_MODEL:-opus}"; EFFORT="${REPLAY_EFFORT:-low}"; K="${REPLAY_K:-1}"
PDIR="$(cd "${REPLAY_PLUGIN_DIR:-$PLUGIN_DIR}" && pwd)"; JOBS="${REPLAY_JOBS:-4}"
PC="${REPLAY_POSTCOMPACT:-}"; [ "$PC" = 0 ] && PC=""
AFTER_DEFAULT="Continue. What is the state of this run and what is your next step?"
BUDGET="${REPLAY_BUDGET_USD:-$([ -n "$PC" ] && echo 8 || echo 4)}"; GUARD="$HERE/replay-guard.py"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
[ $# -gt 0 ] && CASES="$*" || CASES="$(cd "$SET" && ls -d */ 2>/dev/null | tr -d /)"

# The caller may itself be an agent session whose PATH carries an INSTALLED copy of
# this plugin's helpers; the replay must run the helpers of the plugin under test.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.claude/plugins/' -e '/plugins/[^/]*/bin$' | paste -sd: -)"

run_one(){ # <case> <k>
  local c="$1" k="$2" cd_="$SET/$1" o="$OUT/$1.$2" home repo commit
  [ -f "$cd_/ask.md" ] && [ -f "$cd_/commit" ] || { echo "replay: $c lacks ask.md or commit" >&2; return; }
  commit="$(tr -d ' \n' < "$cd_/commit")"; home="$(mk_authed_home)"; repo="$(mk_tmp)"; mkdir -p "$o"
  git -C "$SRC" archive "$commit" | tar -x -C "$repo" || { echo "replay: $c: cannot snapshot $commit" >&2; return; }
  # Project-level harness config can start servers and hooks of its own: drop it.
  rm -rf "$repo/.mcp.json" "$repo/.claude/settings.json" "$repo/.claude/settings.local.json" "$repo/.envrc"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.agents/\n' >> .git/info/exclude && git add -A >/dev/null 2>&1 && git commit -qm snapshot )
  # The operator's own standing preferences shape how a router asks; carry them.
  [ -f "$HOME/.claude/CLAUDE.md" ] && cp -L "$HOME/.claude/CLAUDE.md" "$home/.claude/CLAUDE.md" 2>/dev/null
  mkdir -p "$home/.claude/skills"
  for s in grill-with-docs grill-me brainstorming; do
    [ -d "$HOME/.claude/skills/$s" ] && cp -rL "$HOME/.claude/skills/$s" "$home/.claude/skills/" 2>/dev/null
  done
  cat > "$o/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Agent|Task|Bash|Read|Write|Edit|Glob|Grep|NotebookEdit|WebFetch|WebSearch|mcp__.*","hooks":[{"type":"command","command":"python3 $GUARD","timeout":10}]}]}}
JSON
  # The snapshot may carry the source repo's own tracked board; score only what this run adds.
  { wc -l < "$repo/.agents/runs/orchestrate/board.jsonl" 2>/dev/null || echo 0; } | tr -d ' ' > "$o/board.base"
  local board="$repo/.agents/runs/orchestrate/board.jsonl"
  local cargs=(-p --model "$MODEL" --effort "$EFFORT" --plugin-dir "$PDIR" --settings "$o/settings.json"
               --max-budget-usd "$BUDGET" --allowedTools "Read,Grep,Glob,Write,Edit,Bash,Agent,Task,Skill")
  # /usr/bin/env, not `env`: an interactive caller's shell may define an `env` function.
  session(){ ( cd "$repo" && /usr/bin/env -i \
      HOME="$home" PATH="$CLEAN_PATH" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
      ${ANTHROPIC_API_KEY:+ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
      ${ANTHROPIC_DEFAULT_OPUS_MODEL:+ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL"} \
      REPLAY_ALLOW_AGENTS="${REPLAY_ALLOW_AGENTS:-}" REPLAY_LOG="$o/guard.jsonl" REPLAY_ROOTS="$repo:$home:$PDIR:$_INT_RUN_DIR" \
      "$@" ); }
  { printf '/orchestrate:init '; cat "$cd_/ask.md"; } > "$o/turn1.md"
  if [ -z "$PC" ]; then
    session timeout 900 claude "${cargs[@]}" --output-format json < "$o/turn1.md" > "$o/result.json" 2> "$o/stderr.txt"
  else
    printf '/compact\n' > "$o/compact.md"
    if [ -f "$cd_/after.md" ]; then cp "$cd_/after.md" "$o/after.md"; else printf '%s\n' "$AFTER_DEFAULT" > "$o/after.md"; fi
    cp "$PDIR/skills/orchestrate/SKILL.md" "$o/skill.md" 2>/dev/null
    session timeout 2700 python3 "$HERE/replay-turns.py" --split "$o/guard.jsonl" --lines "$board" \
        "$o/turn" "$o/turn1.md" "$o/compact.md" "$o/after.md" -- claude "${cargs[@]}" > /dev/null 2> "$o/stderr.txt"
    mv "$o/turn.1.json" "$o/result.json" 2>/dev/null; mv "$o/turn.2.json" "$o/compact.result.json" 2>/dev/null
    mv "$o/turn.3.json" "$o/turn2.result.json" 2>/dev/null
    mv "$o/guard.jsonl.turn1" "$o/guard.jsonl" 2>/dev/null; mv "$o/guard.jsonl.turn2" "$o/guard.compact.jsonl" 2>/dev/null
    mv "$o/guard.jsonl.turn3" "$o/guard.turn2.jsonl" 2>/dev/null
    # Rows journaled after the compaction (turn 2 only).
    local after_compact
    after_compact="$(python3 -c 'import json,sys;print(list(json.load(open(sys.argv[1]))["_lines"].values())[0])' "$o/compact.result.json" 2>/dev/null || echo 0)"
    tail -n +"$(( after_compact + 1 ))" "$board" > "$o/board.turn2.jsonl" 2>/dev/null
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("result",""))' "$o/turn2.result.json" > "$o/turn2.say.md" 2>/dev/null
  fi
  tail -n +"$(( $(cat "$o/board.base") + 1 ))" "$board" > "$o/board.jsonl" 2>/dev/null
  cat "$home"/.claude/projects/*/*.jsonl > "$o/transcript.jsonl" 2>/dev/null
  # Everything the session changed since the snapshot, committed or not.
  ( cd "$repo" && { git diff --name-only "$(git rev-list --max-parents=0 HEAD | tail -1)" 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null; } | grep -v '^\.agents/' | sort -u ) > "$o/changed-files.txt"
  cp -r "$repo/.agents/runs/orchestrate/tickets" "$o/tickets" 2>/dev/null
  cp "$cd_/ask.md" "$o/ask.md"; cp "$cd_/kind" "$o/kind" 2>/dev/null; cp "$cd_/key.md" "$o/key.md" 2>/dev/null
  python3 - "$o" <<'PY' > "$o/say.md" 2>/dev/null
import json,sys
try: print(json.load(open(sys.argv[1]+"/result.json")).get("result",""))
except Exception as e: print("(no result: %s)" % e)
PY
}

n=0
for c in $CASES; do for k in $(seq 1 "$K"); do
  run_one "$c" "$k" & n=$((n+1)); [ $((n % JOBS)) -eq 0 ] && wait
done; done; wait

# Scorecard, from the rows this run journaled and the guard's log.
#   asked          a clarify row before any refused dispatch (or with none)
#   went:<persona> first refused dispatch, with no clarify before it
#   inline         the router changed project files itself and dispatched no builder
#   idle           none of the above
# read = a reading file was written; verdict = an allowed assessor's verdict;
# rows = board rows journaled; edits = project files changed; asks = question
# marks in the closing message; then the cost of getting this far.
printf '%-24s %-7s %-15s %-4s %-4s %-9s %-4s %-5s %-4s %-5s %-5s %s\n' case kind outcome tier read verdict rows edits asks turns secs cost
for o in "$OUT"/*/; do python3 "$HERE/replay-score.py" "$o"; done | tee "$OUT/scorecard.txt"
[ -n "$PC" ] && { echo; python3 "$HERE/replay-postcompact-score.py" --header
  for o in "$OUT"/*/; do [ -f "$o/compact.result.json" ] && python3 "$HERE/replay-postcompact-score.py" "$o"; done; } \
  | tee "$OUT/scorecard-postcompact.txt"
exit 0
