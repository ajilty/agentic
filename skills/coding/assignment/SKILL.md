---
name: assignment
description: Run described work end-to-end as a decision-gated project; grill, research and plan, briefing gate with a decisions memo, then build, verify, close out.
disable-model-invocation: true
---

# Assignment

Run one described goal from ambiguity to shipped, decision-gated work. Five
phases, in order; the briefing gates the build.

Each phase's craft lives in a sibling skill directory shipped with this plugin:
Read `../<name>/SKILL.md` relative to this file and apply it as the phase's
guidance. If a named file is missing (partial install), apply the one-line
essence given instead; never stop or fail because a file is absent.

1. **Grill** — resolve ambiguity before any execution. Craft:
   `../grill-with-docs/SKILL.md` when the repo keeps CONTEXT.md or ADRs, else a
   `grill-me` skill if present. Essence: interview the user one question at a
   time with options and a recommendation, exploring the codebase instead of
   asking where it can answer, until the goal is a confirmed acceptance
   criterion.
2. **Investigate and plan (no build yet)** — craft: `../research/SKILL.md`,
   then `../plan/SKILL.md`. If `/orchestrate` is installed, feed the confirmed
   goal to it and run its research and planning lanes, holding build lanes
   until phase 3's memo returns. Essence: read-only findings with
   confirmed-versus-inferred labeling, then a spec with acceptance oracles and
   operator decisions listed, both as durable files.
3. **Brief the operator (the go/no-go gate)** — craft: `../brief/SKILL.md`.
   Essence: an interactive artifact briefing (current state, desired state,
   gaps, options scored against the accepted baseline, plan, FAQ) closing with
   a copyable memo of only the decisions that are the user's to make. Present
   it and stop: nothing is built before the memo returns, and its decisions
   bind the build.
4. **Build and verify** — craft: `../build/SKILL.md`, then `../verify/SKILL.md`
   (via orchestrate's build and verifier lanes when it is running the goal).
   Essence: each builder executes the memo-bound plan in the tree it was
   given, with the commit as the artifact and shared-target steps serial per
   target; a fresh-context agent that did not build it adversarially verifies
   against the goal.
5. **Close out** — craft: `../brief/SKILL.md`, close-out mode. Essence: update
   the same briefing artifact with what shipped versus the plan, deviations and
   why, and any new decisions in the same memo form.
