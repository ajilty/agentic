#!/usr/bin/env bash
# SessionStart(compact) / PostCompact: AUTOMATIC post-compaction recovery. Inject
# the reconstructed board as authoritative context.
#
# Claude Code SessionStart contract: emit
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
# (plain decision JSON is rejected). Build the text, JSON-encode it with jq, exit 0.
# Never aborts. Claude Code wires this through hooks.json; OpenCode's generated plugin
# runs it on session.compacted; Codex wires nothing. The plain fallback below covers
# the no-jq case.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
board="$(bash "$RT/ledger.sh" reground 2>&1)"; rc=$?
head="ORCHESTRATE: context was compacted. The board below is AUTHORITATIVE: treat it
as ground truth over anything summarized. Resume open lanes per the reconciliation;
retry budgets are counted from disk (ledger.sh retries <ticket>), not memory.
FIRST: re-invoke the orchestrate skill to reload the full router brain. Compaction
re-injects invoked skill bodies truncated (~5k-token cap per skill), so the SKILL.md
you are holding now is a stump; do not route from it."
halt=""
[ "$rc" != 0 ] && halt="

HALT: ambiguous in-flight writer after compaction. Do NOT dispatch: re-attach and
reconcile the worktree before continuing."
# Claude Code caps additionalContext at 10,000 characters per field. Keep the header
# the HALT whole, keep reground's summary lines (GOAL, board, REGROUND) whole, put writer
# lines (OPEN WRITER, DIRTY WORKTREE) before read-only ones, and trim what is left over,
# pointing at the full replay.
cap=9500
room=$(( cap - ${#head} - ${#halt} - 2 ))
if [ "${#board}" -gt "$room" ]; then
  sre='^(GOAL:|board:|REGROUND:)'; wre='^(OPEN WRITER|DIRTY WORKTREE)'
  summ="$(printf '%s\n' "$board" | grep -E "$sre" || true)"
  wl="$(printf '%s\n' "$board" | grep -E "$wre" || true)"
  rl="$(printf '%s\n' "$board" | grep -vE "$sre" | grep -vE "$wre" || true)"
  lanes="$wl${wl:+${rl:+
}}$rl"
  more="... (lanes truncated; run ledger.sh reground for the full board)"
  keep=$(( room - ${#summ} - ${#more} - 2 )); [ "$keep" -gt 0 ] || keep=0
  board="${lanes:0:$keep}
$more
$summ"
fi
msg="$head

$board$halt"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$msg"
fi
exit 0
