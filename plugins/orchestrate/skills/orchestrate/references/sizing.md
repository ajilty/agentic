# Right-sizing and context economy

Router reference (core: `../SKILL.md`, loop step 4). Which tier a task takes, which model each persona runs, and when to delegate.

## Right-sizing

Select a tier from counted signals (never asserted), defaulting down:

| Tier | Pipeline | Selected when (all true) |
|------|----------|--------------------------|
| **T0** | one Implementer vs. oracle | task ≤ `tiers.t0_max_files`, no open `#UNKNOWN`, single-file or grep-proven-disjoint, **and the oracle already exists as an independent function probe** |
| **T1** | Implementer → Verifier | above T0 but ≤ `tiers.t1_max_files` and no spec gap (the change is clear, the *check* is what matters) |
| **T2** | full chain | any open `#UNKNOWN`, coupling across files, missing oracle, or above `tiers.t1_max_files` |

Promote a lane that fails its oracle or surfaces an `#UNKNOWN`; never demote
one. The oracle is held-out tests, else spec-derived acceptance checks written
before implementation, else plan one first ("no tests, so it passed" is
`#GAP(no-oracle)`). For a T1 bug fix it is the repro test, red before the fix.
It must be a *function probe*, green only if the feature works, independent of
the writer; a *presence probe* (a file exists, a pod is `Running`) never
qualifies a lane for T0: pair the verifier. For a refactor, ask the operator at
intake "what would you reject?" and write it into the oracle; a refactor-shaped
T1 needs a planner-grade work item, not a bigger implementer.

Each persona's model and effort live in its agent file, compiled from
`agents.yaml`; `inherit` means the persona runs on the main loop's model. The
aliases are Claude Code's; on Codex and OpenCode the installer decides and you
pass no model:

| persona | model | effort |
|---------|-------|--------|
| researcher | haiku | medium |
| planner | inherit | high |
| implementer | sonnet | medium |
| verifier | inherit | high |
| actuator | sonnet | high |

The main loop's model is your own, as your system prompt names it; if unsure,
ask the operator once at intake and journal it as `main_model` on `goal`. Alias
order today is fable > opus > sonnet > haiku; a family you do not recognise
counts as above every alias. A persona never runs a bigger model than the main
loop. An agent file's alias binds even above the main loop, so when the main
loop is at or below a persona's alias, pass the main loop's own alias on the
call (an alias, never `inherit`). Override a dispatch upward only for a named
hard item, within that ceiling, and journal it on `dispatched`. A researcher
whose findings eliminate design options is such an item; a
"correctness-critical" platform is not. After a `REJECTED` verdict that reads
as missed checks, re-dispatch the implementer at `high` effort on the same
model; one that reads as the wrong approach moves the model up one rung within
the ceiling. `max` effort is not a default anywhere.

## Context economy

Your own context is the scarce resource. Delegate when producing a result
takes far more than the result (a wide sweep for one definition, a probe whose
signal is green or red behind hundreds of lines); work inline when comparable.
Hand a diagnosis to a fresh troubleshooter (a researcher in diagnostic mode)
once two inline calls have not resolved it, or before raw logs or a stacktrace
would enter your context; keep only the root cause and fix it returns. It runs
no commands: run what it names with output to
`tickets/<ticket>/logs/<name>.log`, unread, and hand it that path.
