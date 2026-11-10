# The router's core instructions are short, and delivered rather than fetched

## Context

The router worked from one long instruction file (about 26,000 characters). It
reached a session only when the model chose to load it: the start command said
"use the orchestrate skill", and after a compaction a hook said "re-invoke the
skill". The persona craft guides worked the same way: the router was to name
the guide in each dispatch and the persona was to read it.

Measured in November 2026:

- Replays of seven real asks: the instructions were loaded in 1 of 14 runs at
  low effort and 12 of 14 at high effort. With the text injected, 14 of 14 at
  low effort, in less time and at lower cost than high effort.
- A long real session was compacted 20 times and reloaded the instructions 3
  times.
- The router named a craft guide in about 9 of 10 dispatches; about 7 of 10
  persona runs read one.
- Claude Code documents that after a compaction only the first 5,000 tokens
  of each invoked skill are re-attached, that older skills can be dropped
  entirely, and that hook output over 10,000 characters is replaced by a file
  pointer the model is not asked to read.

Runs that lacked the instructions skipped the journal, the sizing step and the
page rules. Adding rules to a file the router often does not hold fixes
nothing.

## Decision

1. **A short core.** `SKILL.md` is the router's core: the trust model, the
   loop with the rules every dispatch, sizing, landing and production change
   must obey, the journal rule and pointers to references. Its printed form
   (`ledger.sh core`) stays under 9,500 characters and a test holds the line.
   The detail each step needs moves to `references/`, named at the step with
   the condition for reading it. Most text moved unchanged; the trust table
   became prose and the routing table gained a row for an approved plan.
2. **One printer.** `ledger.sh core` prints that core and the absolute path of
   the references; `ledger.sh brief` adds the six references a run with a
   writer needs. Every delivery path calls one of them.
3. **Delivered three ways.** The start command injects the brief before the
   model sees anything (a start has no size cap; a live check showed routers
   do not open reference files unprompted). A hook re-attaches the core (not the references) after every compaction. The skill
   itself is now small enough to survive the harness's own re-attach whole.
4. **Craft guides are compiled into the personas** at build time, from a
   mapping in the contract, so a persona holds its guide without anyone
   pointing at it.
5. **The page rules follow the same pattern**: one reference file, injected by
   the status command, read by path at a refresh.

## Considered options

- **Raise effort**: 12 of 14 is not reliable, costs more, and does nothing
  after a compaction.
- **A firmer instruction to load or reload**: this is what was measured
  failing, and the harness's issue tracker records the same.
- **Inject the whole 26,000 characters**: works at the start, is cut after
  the first compaction, and cannot come back through a hook.
- **Two documents, a digest and a full brief**: two sources that drift.

## Consequences

- References are now the weak point: reading one is still the router's choice,
  and a compaction forgets them. The core says to read each again at its step.
  The replay harness measures whether that happens.
- The hook count is four (this adds the core re-attach).
- The re-attach hook cannot tell the router from any other session in the
  repo, so every compacted session where a run was driven receives the core,
  headed by a line saying who it is for. That costs a non-router session about
  2,500 tokens per compaction.
- Codex gets the short core as its skill but no injection and no hook.
  OpenCode gets the injection but no re-attach: its compaction event has no
  documented way to pass a script's output to the model.
- A failed or blocked injection aborts the start command outright (the
  harness's rule), so the printers behind it never fail on content and the
  injected path is quoted.
- Tests that pinned prose in `SKILL.md` now pin it in the reference that holds
  it; `test_core_brief.sh` pins what must stay in the core.

## Amends

0040 and 0042 (the hook count: four).

Status: active
