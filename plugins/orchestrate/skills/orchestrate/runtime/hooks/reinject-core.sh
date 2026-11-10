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
# Only in a repo with an orchestrate board; every other session gets no output.
# Never aborts: any failure is exit 0 with nothing printed.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
_gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
case "$_gcd" in */.git) ;; *) exit 0 ;; esac
[ -f "${_gcd%/.git}/.agents/runs/orchestrate/board.jsonl" ] || exit 0
core="$(bash "$RT/ledger.sh" core 2>/dev/null)" || exit 0
[ -n "$core" ] || exit 0
msg="ORCHESTRATE: your core instructions as router of this run, re-attached after the
compaction. Follow them from loop step 1; they replace the summary's account of the
process, never the operator's own instructions to you in this run. References you read
earlier may be gone or cut short: read each again at its step.

$core"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$msg"
fi
exit 0
