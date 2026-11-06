# Durable router state & resume

The router holds board state, in-flight dispatches, the retry budget, and which
lanes are halted on a fork. Keep none of it only in the context window:
interruption loses it, and compaction summarizes it lossily (a summarized board
with a wrong retry count breaks the "REJECTED → once → human" bound). The
skill's first principle applies to the router itself: *contracts are the bus;
agent memory is never the source of truth*.

The orchestrator **is the driver**: there is no separate driver process and no
config file. `/orchestrate` is the single entry point for starting work and for
resuming an interrupted session; compaction recovers automatically.

## The ledger

`.agents/runs/orchestrate/board.jsonl` is an append-only event journal, the
single source of truth for control state **and** the metrics source (replay to
derive both). A crash mid-write costs at most a trailing partial line, which the
reader discards. Append events **as you drive** the loop in SKILL.md.

**Canonical vocabulary: never invent event names.** Reground, `metrics`, and
`conformance` match on these exact `event` values; an event outside this set is
invisible to all of them. Journal only these, through the `ledger.sh` helpers
(`goal`, `clarify`, `decision`, `done`, or `append '<json>'`, which stamps `ts`
when absent and warns on a non-canonical name). Never `echo >>` the board. Use
`intake` for recording a work item and `clarify` for any clarification (its
`skill` is the mechanism actually used: `inline` when the interactive skills
can't run).

```text
{"ts","event":"goal","note","spec","base"}                              # run-level north star, NO ticket: note = the goal text (reground reads "note"), spec = where the plan lives, base = the integration branch lanes land on. reground surfaces the latest, so a clean board still carries the goal (ADR-0020)
{"ts","ticket","event":"intake","tier","note"}                          # work item recorded + right-sized; tier = T0/T1/T2; note names the task's shared targets
{"ts","ticket","event":"dispatched","persona","dispatch_id","slug","model","effort"}   # BEFORE the persona runs. persona: one of researcher|planner|implementer|verifier|actuator (a troubleshooter journals as researcher). dispatch_id: EVERY dispatch (ADR-0014). slug: researchers only, ticket-unique topic (RAW -> findings/_quarantine/<slug>.<dispatch_id>.md, promoted -> findings/<slug>.md). model/effort: optional, the horsepower actually bound (tier default or a journaled override)
{"ts","ticket","event":"returned","persona","status","artifact","branch"}   # artifact: the PROMOTED findings path (researcher). branch: implementer only, the worktree branch from its report, confirmed with git worktree list
{"ts","ticket","event":"verdict","verdict"}                             # APPROVED|REJECTED|INCONSISTENT_ORACLE
{"ts","ticket","event":"clarify","skill"}                               # intake clarification; ticket="intake" if pre-ticket
{"ts","ticket","event":"fork","state":"halted","fork_id"}
{"ts","ticket","event":"decision","fork_id","adr","note"}               # a resolved fork (adr set iff promoted) or a prod confirmation (fork_id "prod:<target>", answer in note)
{"ts","event":"denied","hook","persona","note"}                         # written by the shared-checkout floor when it stops a command (ADR-0032); never by the router. Counted by metrics (denials), shown by status, harvested by feedback
{"ts","ticket","event":"lane","state":"open|closed","branch"}
{"ts","ticket","event":"done"}                                          # via `ledger.sh done <ticket>`: warns on stderr when a T1/T2 lane has no verdict, and still appends; verify_coverage shows the gap
```

Boards written by 0.8.x may also hold event types and fields from the removed
gates and the dropped model flag, and `branch` on `dispatched`. `metrics`,
`reground`, and `/orchestrate:status` read them; nothing writes them any more.

## Derived, never held

The retry budget is **counted from the ledger at each decision**
(`ledger.sh retries <ticket>` = number of `REJECTED` verdicts for that ticket),
not carried in context, so a lossy compaction cannot reset it. Lane status and
halted forks are read the same way.

## Reground = ledger intent + git ground truth

`ledger.sh reground` reconstructs open lanes two ways and merges them:

1. **Ledger intent.** Tickets whose last event is `dispatched`. A read-only
   persona is safe to re-dispatch if its **promoted result file is absent**: the
   persona writes the RAW `findings/_quarantine/<slug>.<dispatch_id>.md`, and the
   router gates and promotes it to `tickets/<ticket>/findings/<slug>.md` at the
   `slug` on the `dispatched` event. Promoted file present means the result is
   durable; don't re-dispatch. An implementer whose last event is `dispatched`
   is an open writer lane: reconcile it against `git worktree list` before
   dispatching again.
2. **Disk ground truth.** Every live `worktree-*` or `worktree-agent-*`
   worktree with uncommitted work is an open writer lane to reconcile, *even if
   no ledger event exists for it* (missed append, crash mid-write). Disk wins
   over the log. A worktree dirty only with `board.jsonl` is telemetry residue,
   reported and safe to discard.

The run-level `goal` line is printed last, so a clean board never reads as
finished while the plan is open.

## Two resume paths, by cause

- **Interruption (crash / sleep / Ctrl-C) → operator.** Re-run `/orchestrate`.
  Step 1 is reground + reconcile, then continue from the reconstructed board.
- **Compaction → automatic, hands-off.** The compaction hook (Claude Code
  `SessionStart` with source `compact`) runs `ledger.sh reground` and **injects
  the reconstructed board as authoritative state**, plus an instruction to
  re-invoke the skill, because compaction re-injects skill bodies truncated. It
  hands back state rather than a pointer to re-read.

## Halt on an ambiguous writer

If reground finds a dirty writer worktree, it **halts for human re-attach**
(exit 3) rather than guess. Do not dispatch past a halt. A paused board beats a
wrong one.

## Hooks, in total

Two, both on Claude Code only; everything else is the orchestrator driving its
own loop:

- **Shared-checkout floor** (`guard-shared-checkout.sh`, before every Bash
  command, every agent): stops `reset --hard`, `clean -f`, `checkout -f`/`.`/`--`,
  and `switch -f`/`--discard-changes` in the primary checkout, resolved from the
  payload's `cwd`; linked worktrees are left alone. Journals `denied`.
- **Compaction recovery** (`on-compaction.sh`, `SessionStart` matcher
  `compact`): automatic reground + inject, as above.
