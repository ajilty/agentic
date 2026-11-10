#!/usr/bin/env bash
# SessionStart(compact): put the router's core instructions back after a compaction.
#
# Why: a compaction keeps only the first 5,000 tokens of each invoked skill and can
# drop a skill entirely in a skill-heavy session; a resumed session may get nothing
# re-attached at all. Telling the router to reload its instructions did not work
# (measured 2026-11: 20 compactions, 3 reloads). This prints the core itself, so it
# is in context whether or not the router would have gone to fetch it.
#
# Separate from on-compaction.sh on purpose: hook output is capped at 10,000
# characters per hook, and that hook's budget goes to the board.
#
# Only in a repo whose board shows a run was driven (a goal, an intake or a
# dispatch); an empty board, or one holding only another session's refused
# command, gets no output. A hook cannot tell whether THIS session is the router
# (the board records no session), so the text says who it is for and tells any
# other session to ignore it. Never aborts: any failure is exit 0, nothing printed.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
_gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
case "$_gcd" in */.git) ;; *) exit 0 ;; esac
_board="${_gcd%/.git}/.agents/runs/orchestrate/board.jsonl"
[ -f "$_board" ] || exit 0
grep -qE '"event":[[:space:]]*"(goal|intake|dispatched)"' "$_board" 2>/dev/null || exit 0
core="$(bash "$RT/ledger.sh" core 2>/dev/null)" || exit 0
[ -n "$core" ] || exit 0
msg="ORCHESTRATE: core instructions for the session driving this repo's run, re-attached
after the compaction. Any other session: ignore this; it starts nothing. Router: follow
them from loop step 1. They replace the summary's account of the process, never the
operator's own instructions. Read each reference again at its step.

$core"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$msg"
fi
exit 0
