---
description: "Standing operator loop: feed a goal of any altitude; re-run with no args to resume."
argument-hint: "[goal…]"
---

# Orchestrate operator loop

You are running the **orchestrate** standing operator loop. Use the `orchestrate`
skill; its `SKILL.md` is the router brain. Drive the numbered loop in order:
reground (always first) → intake and goal → clarify if no oracle is nameable →
right-size → drive lanes (Researcher / Planner / Implementer / Actuator /
Verifier) → verify → land → feedback. Escalate forks and quarantine to the
operator; never thrash.

The work item for intake (loop step 2) follows. If it is empty, this is a
**resume**: run step 1 (`ledger.sh reground`) and continue the open lanes
instead of starting new work.

$ARGUMENTS
