# Writer worktrees cut from the journaled goal base, not the operator's current checkout

Third branch-drift incident across two runs, new form (2026-07-15 review): a writer
worktree was created off `artlicursi-cutover` — a parked, operator-gated cutover branch
the operator happened to have checked out — instead of master. Only the Verifier's
downstream-breakage check stopped a naive merge from dragging gated DNS-cutover work into
master. ADR-0027 gated *merges* against the journaled base; worktree *creation* still
defaulted to the current branch (ADR-0013's fix for the origin/HEAD stale-orphan trap),
which is exactly the door a stale operator checkout walks through.

**Decision.** `worktree.sh` base resolution becomes: explicit arg > **journaled goal
`base`** (board `goal` event, same source guard-merge-base reads) > current branch > main.
A conformant run (SKILL journals `base` at intake since 0.8.13) now cuts every writer
worktree from the intended integration branch regardless of what the operator has checked
out; the current-branch fallback remains for boards without a goal base. Covered in
`test_worktree.sh` (goal base outranks current branch; explicit arg still outranks both).

## Considered options
- **Keep current-branch default, rely on the merge gate** — rejected: ADR-0027 catches the
  merge, but the writer has by then built on the wrong base — wasted lane + a reconcile.
  Catch it at creation, where it is free.
- **HALT when goal base and current branch differ** — rejected: the mismatch is routine
  (operator parks branches mid-cutover); the journaled intent is authoritative, so use it.
- **Read base from origin/HEAD** — rejected long ago (ADR-0013 stale-orphan trap).

## Consequences
- One resolution step added to `worktree.sh`; precedence documented in-file. Runs without
  a journaled base behave exactly as before.
- With ADR-0027, both ends of the branch-drift class are now closed: creation cuts from
  the journaled base, and merges are gated against it.

## Status

active

_Status: superseded by 0040_
