# Dispatch model policy is a run-level operator toggle riding the goal anchor

The §2a′ tier table fixed per-persona horsepower (ADR-0024/0025), but the operator has no
lever over the *policy* those defaults implement: sessions where cost matters more than
depth, or where "just use what the main loop uses" is the honest intent, had no sanctioned
expression — the only options were the table or ad-hoc per-dispatch overrides.

**Decision.** A run-level `model_policy` with three values, set by the operator at intake
or flipped mid-run, journaled on the **goal anchor** (`ledger.sh goal "<note>" [spec]
[base] [policy]`) so it needs no config file, survives compaction, and the latest goal
wins on reground:

- **`dynamic`** (default): the §2a′ table + escalation tripwires, unchanged.
- **`quick`**: dynamic but lean cheaper/faster — each row shifts one step down (model
  first: opus→sonnet, sonnet→haiku; already-haiku rows drop effort high→medium).
  Escalation stays live so a *named* sharp item still climbs. Floor: a T2 verifier
  never drops below sonnet/high.
- **`inherit`**: pass no model/effort at dispatch — personas run the main loop's model;
  journaled as `model:"inherit"` so `model_mix` stays honest. On a flagship main loop
  this recreates the all-flagship spend ADR-0024 fought, so status flags the mode
  visibly rather than letting it read as default behavior.

## Considered options
- **A config file / env var** — rejected: "no config file is read" is a standing design
  principle; the board already carries run-level state durably.
- **Per-dispatch operator overrides only** — rejected: that is the status quo; it puts a
  recurring decision on the operator instead of a one-time policy.
- **Renaming `quick` as `cheap`** — rejected by the operator: the mode is *dynamic with
  less effort*, not a race to the cheapest model; the name should say what it does.

## Consequences
- `metrics model_mix` + the feedback row now audit policy compliance per release: a
  `quick` run showing opus researchers, or an unflagged `inherit` run, is visible drift.
- The policy applies at dispatch time; changing it mid-run affects future dispatches
  only — in-flight personas keep the horsepower they were dispatched with.

## Status

active

_Status: superseded by 0040_
