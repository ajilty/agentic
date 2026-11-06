# Personas carry their boundaries up front; hooks are the backstop, not the syllabus

Live sighting (2026-07-20, infrastructure): a verifier executing its required
counterfactual check (prove the new tests go red without the fix) tried `git checkout`
(denied by run-scope), then `git show` + `cp` over the worktree (denied), and only on the
third attempt improvised the sanctioned move (replicate the tree into scratch, revert the
copy). The hooks worked exactly as designed — and the persona still burned two denials
discovering a boundary the contract could have told it. The worse variant is the persona
that improvises *differently*: skips the counterfactual, or "verifies" by reading the
diff. Every capability subtraction we enforce but do not narrate invites this.

**Decision.** Every persona body opens with a uniform **"Your boundaries (fail-closed
hooks — don't discover them by denial)"** section: each refusal the hooks enforce, stated
as a rule, *paired with the sanctioned alternative* (verifier: `git archive` into
`$TMPDIR`, revert the copy, run there, delete after; implementer: `NEEDS_CONTEXT` over
branch renames, `#GAP(stale-base)` over `reset --hard`; researcher: patch *proposals* in
findings; planner: declare the oracle, never run it; actuator: surface the gate, wait for
the ack). Hooks remain fail-closed and unchanged — they are the backstop for the persona
that ignores its briefing, not the mechanism by which it learns the rules.

## Considered options
- **Keep discovery-by-denial** — rejected: measured to waste turns, and the un-narrated
  boundary invites silent workarounds that are worse than the denial (skipping the
  red-check entirely).
- **Relax the hooks where personas bump them** — rejected: every denial in the sighting
  was correct; the gap was context, not enforcement.
- **Centralize one boundaries doc the router injects per dispatch** — rejected: the
  persona body already IS the per-dispatch context; a second artifact adds assembly
  work for no isolation gain.

## Consequences
- Personas attempt the sanctioned pattern first; denials shrink to genuine contract
  violations, which ADR-0032 now measures (`denials` metric) — making this ADR's own
  effectiveness observable.
- The boundary sections must track agents.yaml/hook changes; the build drift-guard
  keeps compiled agents in sync with the persona sources.

## Status

active

## Amended by ADR-0040

Boundaries are the whole syllabus: hooks are no longer a backstop. Each persona brief states what it does and does not do, and nothing enforces it beyond the shared-checkout floor.
