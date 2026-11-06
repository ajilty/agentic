# Merges on the shared checkout must land on the journaled integration base

Field failure ×2 in one session (2026-07-14 feedback): a lane merge landed on a bystander
branch the operator happened to have checked out (`artlicursi-cutover`). The router never
asserted HEAD before merging; the shared-checkout guard (ADR-0013) caught second-order
damage but nothing prevented the mis-landed merge itself. Operator ask, verbatim:
"checking `git rev-parse --abbrev-ref HEAD` before every merge should be mechanical."

**Decision.** Make it mechanical, keyed on journaled intent:
- The `goal` event (ADR-0020) gains an optional third field, `base` — the integration
  branch merges must land on, journaled at intake (`ledger.sh goal <note> [spec] [base]`).
- A new persona-independent PreToolUse floor, `guard-merge-base.sh`, denies a `git merge`
  on the **primary** checkout when HEAD differs from the latest journaled `base`.
  Fail-open when no base is journaled (the floor keys only on explicit intent, like the
  pre-apply gate's ack files) and in linked worktrees (a writer's in-sandbox merge is
  keep-on-branch's concern). SKILL step 4 orders the assert in prose; the hook is the
  backstop when the prose is skipped — the same prose+floor pairing as the done-gate.

## Considered options
- **Prose-only ("check HEAD before merging")** — rejected: this failed twice live; the
  repo's standing rule is that can't-tolerate misses become hooks (agents.yaml hooks
  preamble), and a mis-landed merge on a shared checkout is that class.
- **Derive the base implicitly (current branch at first dispatch, origin/HEAD)** —
  rejected: implicit bases are the stale-orphan trap ADR-0013 exists for; the operator's
  intent is journaled explicitly or the floor stays open.
- **Fold into guard-shared-checkout** — rejected: that floor is about destructive ops and
  fires persona-wide on token patterns; merge-vs-base is a different predicate (board
  lookup + branch compare) with different fail-open semantics. One concern per hook.

## Consequences
- New hook wired in hooks.json (Claude Code); `goal` schema extended (resume.md); SKILL
  intake + merge steps updated; covered in `test_hooks_safety.sh` (deny on bystander
  HEAD, allow on base/no-base/non-merge/linked-worktree) and `test_goal_anchor.sh`.
- A run that never journals `base` gets no protection — the SKILL now journals it at
  intake, so a conformant run is protected by default.

## Status

active

_Status: superseded by 0040_
