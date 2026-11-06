# The verifier run-scope floor carves out scratch roots for rehearsals

Field failure ×2 (2026-07-14 feedback, two consecutive runs): the run-scope floor denied
**any** write, so verifiers degraded exactly where verification quality lives — a
stubbed-aws rehearsal fell back to static analysis (below the ADR-0022 function-proof
bar), and a verifier assembled its result sentinel via `chr(62)` to get output past the
redirect matcher. The floor's threat model is oracle-gaming (mutating repo/tests/git so
the suite passes); a stub binary or probe script in a throwaway tmpdir is not that threat
— it is the *mechanism* of a live function-proof.

**Decision.** `run-scope.sh` allows file mutations whose targets all resolve under scratch
roots (`/tmp/`, `/var/tmp/`, `$TMPDIR`); everything else stays denied exactly as before:
- Redirects: every `>`/`>>` target must be scratch, else deny (a mixed command with one
  non-scratch target denies whole).
- Mutation verbs (`rm`/`mv`/`tee`/`sed -i`/…): every path-shaped argument must be scratch;
  a relative or repo path anywhere denies — **fail-closed: an unparseable or relative
  target reads as non-scratch**.
- Git mutations stay denied unconditionally (git state is never scratch).

## Considered options
- **Keep the total write ban** — rejected by the measured effect: it lowered verification
  quality (static-analysis fallbacks) and trained verifiers to evade the matcher, both
  worse for the safety story than scratch writes.
- **A dedicated rehearsal lane shape** — rejected as heavier: a second dispatch per
  verification for what a path carve-out solves; revisit if scratch proves insufficient.
- **Session-scratchpad-only (no bare `/tmp`)** — rejected: the scratchpad path is
  harness-specific and not knowable portably in the hook; `/tmp`-rooted is the portable
  superset and stays within the floor's advisory denylist posture (ADR-0002/ADR-0010).

## Consequences
- Loosens a floor, deliberately and narrowly; the oracle-gaming surface (repo, tests, git)
  is unchanged. Covered by regression cases in `test_hooks_safety.sh` (allow scratch
  redirect/tee/rm + `$TMPDIR`; deny repo-relative, mixed-target, `sed -i` on repo, git
  under scratch).
- Verifier rehearsals (ADR-0022 function probes) can now execute rather than degrade.

## Status

active

_Status: superseded by 0040_
