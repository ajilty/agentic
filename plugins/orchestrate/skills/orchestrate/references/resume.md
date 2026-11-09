# Durable router state & resume

The router holds board state, in-flight dispatches, the retry budget, and which
lanes are halted on a fork. Keep none of it only in the context window:
interruption loses it, and compaction summarizes it lossily (a summarized board
with a wrong retry count breaks the "REJECTED → once → human" bound). Contracts
are the bus; agent memory is never the source of truth.

The orchestrator **is the driver**: there is no separate driver process and no
config file. `/orchestrate:init` is the single entry point for starting work
and for resuming an interrupted session; compaction recovers automatically.

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
can't run). ADR numbers below are orchestrate's own, not the target repo's.

```text
{"ts","event":"goal","note","spec","base","main_model"}                 # run-level north star, NO ticket: note = the goal text (reground reads "note"), spec = where the plan lives, base = the integration branch lanes land on, main_model = the router's own model (the ceiling for personas). reground surfaces the latest, so a clean board still carries the goal (orchestrate ADR-0020)
{"ts","ticket","event":"intake","tier","note"}                          # work item recorded + right-sized; tier = T0/T1/T2; note names the task's shared targets
{"ts","ticket","event":"dispatched","persona","dispatch_id","slug","lens","model","effort"}   # BEFORE the persona runs. persona: one of researcher|planner|implementer|verifier|actuator (a troubleshooter journals as researcher). dispatch_id: EVERY dispatch (orchestrate ADR-0014). slug: researchers only, ticket-unique topic (RAW -> findings/_quarantine/<slug>.<dispatch_id>.md, promoted -> findings/<slug>.md). lens: act|fit|break for an instructions verifier. model/effort: optional, the horsepower actually bound
{"ts","ticket","event":"returned","persona","status","artifact","branch"}   # artifact: the PROMOTED findings path (researcher). branch: implementer only, the worktree branch from its report, confirmed with git worktree list
{"ts","ticket","event":"verdict","verdict","mode","round","artifact"}   # APPROVED|REJECTED|INCONSISTENT_ORACLE. mode: "plan" for a plan-mode verdict on the spec (spends no implementer retry, not verify coverage); the spec as reviewed is pinned beside it at verdicts/<ticket>.<dispatch_id>.spec.md so a re-review diffs instead of re-reading. An instructions lane journals ONE row per round of lens verifiers (REJECTED if any lens rejects), round = N, artifact = verdicts/<ticket>.round<N>.md, the merged findings the router writes
{"ts","ticket","event":"clarify","skill"}                               # intake clarification; ticket="intake" if pre-ticket
{"ts","ticket","event":"fork","state":"halted","fork_id"}               # a DECISION_FORK, or a prod confirmation the router is waiting on (fork_id prod-ack:<target>)
{"ts","ticket","event":"decision","fork_id","adr","note"}               # a resolved fork (adr set iff promoted) or a prod confirmation: ledger.sh decision <ticket> prod-ack:<target> "" "<approved|declined>: <one line>" (the operator's answer, either way, in note)
{"ts","event":"denied","hook","persona","note"}                         # written by the shared-checkout floor when it stops a command (orchestrate ADR-0032); never by the router. persona = the payload's agent_type, "-" for the main session. Counted by metrics (denials), shown by status, harvested by feedback
{"ts","ticket","event":"lane","state":"open|closed","branch"}
{"ts","ticket","event":"done"}                                          # via `ledger.sh done <ticket>`: warns on stderr when a T1/T2 lane has no outcome verdict, and still appends; verify_coverage shows the gap
```

Boards written by 0.8.x may also hold event types and fields from the removed
gates and the dropped model flag (`lease-conflict`, `gate-blocked`,
`model_policy`), and `branch` on `dispatched`. `metrics` and `reground` read
them without error: `lease-conflict` still counts as friction, the others are
ignored, and nothing writes them any more. A 0.8.x lane left open (last event
`dispatched` with a `branch`) closes when you append its `returned` from what is
on disk, or `ledger.sh done` once it has landed.

0.8.x also kept run state outside the board: `active-writer.json` (the single
writer's lease), `leases/` (target leases), and per-ticket `lease` and `ack-*`
files. No current version reads them, and a leftover copy is not a writer limit. Reground moves them into
`.agents/runs/orchestrate/legacy/<timestamp>/` and prints a `LEGACY STATE:` line
the first time it sees them; tell the operator, and delete the folder whenever.

## Derived, never held

The retry budget is **counted from the ledger at each decision**
(`ledger.sh retries <ticket>` = number of outcome `REJECTED` verdict rows for
that ticket, one per round), not carried in context, so a lossy compaction
cannot reset it. Lane status and halted forks are read the same way.

## Reground = ledger intent + git ground truth

`ledger.sh reground` reconstructs open lanes two ways and merges them. Act on
every line it prints:

1. **Ledger intent**, by each ticket's last event; a `done` (or a closed
   `lane`) lane is not listed.
   - `OPEN WRITER ... persona=implementer branch=unknown`: dispatched, no
     `returned`; in flight or crashed. **Check the writer's result file first**:
     `tickets/<ticket>/results/<dispatch_id>.md` ending with the completion
     sentinel (in the run dir, else the same path inside the lane's worktree)
     means the work finished and only the journal is behind — journal `returned`
     from it and route. Only with no result file, match each
     unclaimed worktree by this ticket's id in its commit subjects (`git -C
     <path> log --oneline origin/<base>..HEAD`): a match may hold this writer's
     commits, so adopt them (journal `returned`) or ask the operator.
   - `OPEN WRITER ... persona=actuator`: in flight or crashed. Check its result
     file the same way: a sentinel-complete file is the finished report, so
     route it instead of waking the operator. Never re-dispatch
     an actuator without confirming with the operator; it is never a re-dispatch
     candidate.
   - `OPEN READONLY` / `READONLY DONE`: a researcher, planner, or verifier.
     Re-dispatch only if its promoted result file is absent: the persona writes
     the RAW `findings/_quarantine/<slug>.<dispatch_id>.md`, and the router
     gates and promotes it to `tickets/<ticket>/findings/<slug>.md`.
   - `OPEN LANE ... last=<event>`: a parked lane, so it survives compaction:
     `returned` (awaiting its verdict), `verdict:APPROVED` (awaiting landing),
     `verdict:REJECTED` (awaiting fix: attach the `artifact` of the ticket's latest verdict row to the retry), `plan-verdict:*`, `fork` (halted,
     awaiting the operator), `intake` (not yet dispatched), `clarify`,
     `decision`. Resume each from that event.
2. **Disk ground truth**, scoped to this run. A worktree is a lane of this run
   when its branch is named on a `dispatched`, `returned`, or `lane` row, or it
   lives under `.claude/worktrees/` or `.agents/worktrees/` on a branch naming a
   ticket on the board. Every other worktree belongs to another session: it is
   counted once as `OTHER WORKTREES (not this run): <n>` and never judged.
   - `DIRTY WORKTREE ... in flight or crashed; confirm before re-dispatch`: a
     lane of this run with uncommitted work and a `dispatched` row.
   - `DIRTY WORKTREE ... no dispatched row`: uncommitted work in a lane the
     ledger lost. A HALT (exit 3).
   - `UNJOURNALED WRITER`: a dirty `worktree-agent-*` tree (orchestrate's own
     naming) that no board row names. HALT (exit 3); reconcile before
     dispatching. Harness-named `worktree-*` trees stay in `OTHER WORKTREES`.
   - `TELEMETRY RESIDUE`: a tree dirty only with `board.jsonl`, in any
     worktree; reported, safe to discard.

The run-level `goal` line is printed last, so a clean board never reads as
finished while the plan is open. Reground runs under macOS `/bin/bash` 3.2.

## Two resume paths, by cause

- **Interruption (crash / sleep / Ctrl-C) → operator.** Re-run
  `/orchestrate:init` with no goal. Step 1 is reground + reconcile, then
  continue from the reconstructed board.
- **Compaction → automatic, hands-off.** In a repo with a board, the compaction
  hook (Claude Code `SessionStart` with source `compact`) runs `ledger.sh
  reground` and **injects the reconstructed board as authoritative state**,
  plus an instruction to re-invoke the skill, because compaction keeps only
  part of an invoked skill or drops it. With no board it says nothing.

## Halt on a lost lane

The design once halted reground on any dirty writer worktree. That is narrowed
to one case: a lane worktree of this run with uncommitted work and **no
`dispatched` row** (the ledger lost it) halts for the operator (exit 3) rather
than guess. In-flight writers, dirty or not, are reported, never halted, and
other sessions' worktrees are never judged. Do not dispatch past a halt. A
paused board beats a wrong one.

## Hooks, in total

Two on Claude Code (OpenCode's generated plugin runs only the compaction one;
Codex runs none); everything else is the orchestrator driving its own loop:

- **Shared-checkout floor** (`guard-shared-checkout.sh`, before every Bash
  command, every agent): stops the canonical spellings of `reset --hard`,
  `clean -f`, `checkout -f`/`.`/`--`, and `switch -f`/`--discard-changes` aimed
  at the primary checkout. The command is split into shell words (quotes
  honoured) and statements; the target is tracked through `cd`, `pushd`,
  `popd`, subshells, and `git -C`, starting at the payload's `cwd`. A
  destructive verb whose checkout cannot be resolved is refused; without jq any
  destructive verb is refused. Out of scope: `--git-dir`/`--work-tree`,
  `GIT_DIR=`, `sh -c`/`eval`/`xargs`, other discarding verbs, and an operator
  checkout that is itself a linked worktree. Journals `denied`.
- **Compaction recovery** (`on-compaction.sh`, `SessionStart` matcher
  `compact`): automatic reground + inject, as above, only where a board exists.
