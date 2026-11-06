#!/usr/bin/env bash
# SessionStart(compact) / PostCompact: AUTOMATIC post-compaction recovery. Inject
# the reconstructed board as authoritative context.
#
# Claude Code SessionStart contract: emit
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
# (plain decision JSON is rejected). Build the text, JSON-encode it with jq, exit 0.
# Never aborts. Claude Code wires this through hooks.json; OpenCode's generated plugin
# runs it on session.compacted; Codex wires nothing. The plain fallback below covers
# the no-jq case. No board at the git common root: exit 0, no output.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
# Only a repo with an orchestrate board gets anything: every other session's compaction
# (no git, no board, non-code work) passes through silently, with no output at all.
_gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
case "$_gcd" in */.git) ;; *) exit 0 ;; esac
[ -f "${_gcd%/.git}/.agents/runs/orchestrate/board.jsonl" ] || exit 0
board="$(bash "$RT/ledger.sh" reground 2>&1)"; rc=$?
head="ORCHESTRATE: context was compacted in a repo with an orchestrate board. The board
below is AUTHORITATIVE: treat it as ground truth over anything summarized. Resume open
lanes per the reconciliation; retry budgets are counted from disk (ledger.sh retries
<ticket>), not memory.
FIRST: re-invoke the orchestrate skill to reload the full router brief. Compaction keeps
only the first part of each invoked skill and may drop it entirely in a skill-heavy
session, so do not route from what you hold now."
halt=""
if [ "$rc" = 3 ]; then halt="

HALT: a lane worktree holds uncommitted work the board has no dispatched row for. Do NOT
dispatch: show the operator and reconcile it first."
elif [ "$rc" != 0 ]; then halt="

HALT: ledger.sh reground failed (exit $rc), so the board above may be incomplete. Do NOT
dispatch until it runs clean; run it yourself and show the operator the error."
fi
# Claude Code caps additionalContext at 10,000 characters per field. Keep the header and
# the HALT whole, keep reground's summary lines (GOAL, board, OTHER WORKTREES, REGROUND)
# whole, put writer and parked-lane lines (OPEN WRITER, DIRTY WORKTREE, OPEN LANE) before
# read-only ones, and trim what is left over, pointing at the full replay.
cap=9500
room=$(( cap - ${#head} - ${#halt} - 2 ))
if [ "${#board}" -gt "$room" ]; then
  sre='^(GOAL:|board:|OTHER WORKTREES|REGROUND:|LEGACY STATE:)'; wre='^(OPEN WRITER|DIRTY WORKTREE|OPEN LANE)'
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
