#!/usr/bin/env bash
# Tier 3c, replay: run past opening asks through the router and score what it
# does BEFORE any work starts. The before/after measure for intake changes
# (clarify, sizing): did the router ask, and what, or did it start dispatching?
# The engine is the repo's scripts/replay/replay.sh (case format, environment,
# output files and safety are documented there); this file is orchestrate's
# settings for it and orchestrate's two scorecards.
#
#   bash tests/eval/replay.sh <set-dir> <source-repo> <out-dir> [case ...]
#
# Cases may also carry <case>/kind (big | control; a control must draw no
# question) and <case>/key.md (what later changed, for whoever grades the run).
# REPLAY_PLUGIN_DIR defaults to this checkout. REPLAY_POSTCOMPACT=1 adds the
# second scorecard: does the router still hold and follow its instructions
# after a compaction?
#
# Reporting only; never a CI gate.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${3:?usage: replay.sh <set-dir> <source-repo> <out-dir> [case ...]}"
export REPLAY_PLUGIN_DIR="${REPLAY_PLUGIN_DIR:-$HERE/../..}" REPLAY_PREFIX='/orchestrate:init ' \
  REPLAY_JOURNAL=.agents/runs/orchestrate/board.jsonl REPLAY_CARRY_SKILLS="grill-with-docs grill-me brainstorming" \
  REPLAY_KEEP=.agents/runs/orchestrate/tickets
# The engine's own one-line-per-run summary is kept in <out-dir>/summary.txt; show only a skip.
mkdir -p "$OUT" && : > "$OUT/.started"
bash "$HERE/../../../../scripts/replay/replay.sh" "$@" | grep '^(skip'; rc="${PIPESTATUS[0]}"
[ "$rc" = 0 ] || exit "$rc"
[ -f "$OUT/summary.txt" ] || exit 0   # the engine skipped
# The brief under test, kept beside each run this call produced; a run left by an earlier call keeps its own.
for o in "$OUT"/*/; do [ "$o" -nt "$OUT/.started" ] && cp "$REPLAY_PLUGIN_DIR/skills/orchestrate/SKILL.md" "$o/skill.md" 2>/dev/null; done
# The scorers read files the session wrote: one in an unexpected shape costs that run its line, not the scorecard.
score(){ python3 "$@" 2>/dev/null || printf '%-24s (not scored: the scorer failed on this run's files; run it on the directory to see why)\n' "$(basename "${@: -1}")"; }
clean(){ LC_ALL=C tr -cd '[:print:]\n'; }   # scorecards carry session-written text: never raw to the terminal

# Scorecard, from the rows this run journaled and the guard's log.
#   asked          a clarify row before any refused dispatch (or with none)
#   went:<persona> first refused dispatch, with no clarify before it
#   inline         the router changed project files itself and dispatched no builder
#   idle           none of the above
# read = a reading file was written; verdict = an allowed assessor's verdict;
# rows = board rows journaled; edits = project files changed; asks = question
# marks in the closing message; then the cost of getting this far.
printf '%-24s %-7s %-15s %-4s %-4s %-9s %-4s %-5s %-4s %-5s %-5s %s\n' case kind outcome tier read verdict rows edits asks turns secs cost
for o in "$OUT"/*/; do score "$HERE/replay-score.py" "$o"; done | clean | tee "$OUT/scorecard.txt"
case "${REPLAY_POSTCOMPACT:-0}" in 0|"") ;; *) { echo; python3 "$HERE/replay-postcompact-score.py" --header
  for o in "$OUT"/*/; do [ -f "$o/compact.result.json" ] && score "$HERE/replay-postcompact-score.py" "$o"; done; } \
  | clean | tee "$OUT/scorecard-postcompact.txt" ;; esac
exit 0
