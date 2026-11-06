# Per-dispatch enforcement context via an on-disk active-writer record

The prod-gate needs the dispatch's `PROD_TARGETS` and the branch-guard needs its
`ASSIGNED_BRANCH`. The router has these; the hooks do not. Claude Code passes a
subagent's hooks only the stdin payload (`agent_type`, `tool_input`, `agent_id`,
`cwd`) — never router-set env — and the router doesn't know the CC-generated
`agent_id` at dispatch time, so the two sides share no key. Without a bridge the
gate/branch hooks no-op under CC (held-out + capability allowlists still hold).

**Decision.** The router writes an on-disk **active-writer record** —
`.agents/runs/orchestrate/active-writer.json` `{ticket, persona, prod_targets,
assigned_branch, ts}` — immediately before dispatching a writer, and clears it on
lane close. The hooks read it (env stays the Codex/OpenCode fallback). This is
"disk is the source of truth" applied to the hook layer: per-dispatch context
travels through a durable artifact, not env.

## Status

accepted

## Considered options

- **Pass via the subagent prompt** — the hooks never see the prompt. Rejected.
- **Correlate by `agent_id`** — the router can't know the CC-generated `agent_id`
  before the subagent starts, so it can't pre-write `agent_id → ticket`. Rejected.
- **Give up on hook enforcement under CC** — leaves the prod gate hollow. Rejected.

## Consequences

- Gate + branch-guard enforce under CC once the record exists.
- **Single-writer** makes one record sufficient; **parallel writers** would need
  per-`agent_id` records — deferred (matches the existing single-router/serialized
  -writer assumptions). *Amended by ADR-0039 (2026-11-06): the record is now one
  file per persona, after a live builder-plus-actuator overlap left the gate inert;
  per-ticket records remain deferred.*
- The router writing/clearing the record is loop discipline (like the other
  in-loop ledger appends), via `ledger.sh writer-ctx set|clear`.
- `reground` HALTs on a dangling record (a writer that didn't cleanly close),
  forcing reconcile (`writer-ctx clear`) so a stale, already-acked record can't
  bypass the gate on a later dispatch. It does not auto-clear — at compaction the
  record may belong to a live writer.
