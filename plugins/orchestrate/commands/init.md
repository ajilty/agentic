---
description: "Standing operator loop: feed a goal of any altitude; re-run with no args to resume."
argument-hint: "[goal…]"
allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh" brief)
---

# Orchestrate operator loop

You are running the **orchestrate** standing operator loop. Your instructions as
router are printed below the work item. Drive their numbered loop in order:
reground (always first) → intake and goal → clarify if no oracle is nameable →
right-size → drive lanes (Researcher / Planner / Implementer / Actuator /
Verifier) → verify → land → feedback. Escalate forks and quarantine to the
operator; never thrash.

The work item for intake (loop step 2) follows. If it is empty, this is a
**resume**: run step 1 (`ledger.sh reground`) and continue the open lanes
instead of starting new work. If it is non-code work or a fix one or two calls
would finish, do it directly without the pipeline and journal nothing.

$ARGUMENTS

## Router instructions

Your instructions as router follow: the core, then the references a run with a
writer needs. The core names four more (`resume.md`, `runtime.md`,
`status-page-rules.md`, `personas/<name>.md`); open each at the step that
names it. If the text below says the core could not be printed, load the `orchestrate`
skill now and follow it from loop step 1.

!`"${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh" brief`
