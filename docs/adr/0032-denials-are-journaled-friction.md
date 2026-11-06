# Every enforcement denial is journaled to the board; instrumentation over a verbose mode

The operator relayed a verifier's denial-and-workaround sequence by pasting chat — the
exact failure ADR-0028 exists to end — and asked for "a feedback/verbose mode" so this
class of friction reaches the dev loop. A mode was considered and rejected: it works only
while someone remembers it is on, costs operator attention (a chattier router), and
depends on the model narrating reliably. The friction signal already exists at a
deterministic point: the hook's own deny path.

**Decision.** Every enforcement hook (run-scope, write-scope, deny-heldout-read,
guard-shared-checkout, guard-merge-base, keep-on-branch), when it denies, also journals a
canonical **`denied`** event to the board — `{hook, persona, note}` (first ~80 chars of
the refused command/path), via an EXIT trap so every exit-2 path is covered by one
insertion. Journaling never blocks and never alters the deny: board absent → skip;
`ledger.sh` failure → swallowed; explicit exit codes survive the trap; stdout stays
clean (the CC allow contract). Downstream, `metrics` counts `denials=N`, the feedback
row carries it, `/orchestrate:status` surfaces it, and the dev-side harvest reads the
incident without operator relay. `gate-blocked` (prod gate) predates this and stays as
the richer, key-carrying record for that one gate.

## Considered options
- **Operator-toggled verbose/feedback mode** — rejected: attention cost, forgettable,
  narration-dependent. Instrumentation is always-on and free.
- **Journal from inside each deny() call site** — rejected: several hooks have multiple
  deny sites with different shapes; the EXIT trap covers all of them with one block.
- **Ship denial telemetry off-board (separate log)** — rejected: the board is already
  the single machine-read control record; a second sink needs its own reader.

## Consequences
- Denials are rare by design, so board volume is negligible; a *rising* `denials`
  count now measurably flags a persona missing boundary context (ADR-0031) or a hook
  misfiring — distinguishable by reading the `denied` rows.
- Subagent hooks may run with a cwd that has no board (worktrees); those denials skip
  journaling — accepted, the stderr deny is still visible in-lane.

## Status

active

## Amended by ADR-0040

Only the shared-checkout floor journals denials now; the other enforcement hooks are removed.
