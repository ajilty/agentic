# run-scope mirrors the verifier's verdict-write allowance; one contract, every layer

Recurred twice in one live session (2026-07-21 review): the contract tells the verifier
to persist its verdict to `…/tickets/<ticket>/verdicts/` (disk-first, ADR-0014), and the
write-scope hook has always allowed exactly that path — but verdicts typically land via
**Bash** (heredoc, redirect, `mv` from scratch), and the run-scope floor denied every
non-scratch redirect. The two enforcement layers disagreed about the same sanctioned
write. Measured degradations: one verifier routed around via `cp` (not in run-scope's
verb list — a hole, not a permission), and two refused and returned verdicts in-message,
forcing router-side persistence and violating disk-first.

**Decision.** run-scope carves out exactly the verdicts subtree
(`…/.agents/runs/orchestrate/tickets/*/verdicts/*`) in both its checks (file-mutation
verb arguments and redirect targets), alongside the ADR-0026 scratch roots. Nothing else
widens: source, tests, findings, and all git mutations stay denied. The rule this
generalizes: **when a persona has one sanctioned write, every enforcement layer must
agree on it** — a floor that denies the contract's own required action manufactures
workarounds worse than the write (in-message verdicts are exactly what ADR-0014 exists
to prevent). The verifier boundary section now states the Bash path is sanctioned.

## Considered options
- **Prose-only ("use the Write tool for verdicts")** — rejected: harness-dependent (a
  Codex persona writes via shell), and prose against a denying hook loses — measured.
- **Route verdicts through scratch + router moves them** — rejected: adds a router step
  and a failure window between scratch write and promotion for no isolation gain; the
  verdicts path is already the write-scope-audited destination.
- **Drop the redirect check entirely for the verifier** — rejected: the redirect check
  is what catches oracle-tampering via `echo > tests/…`; the carve-out is surgical.

## Consequences
- Verifiers persist verdicts first-try via either tool path; `denied` telemetry
  (ADR-0032) would now flag any residual mismatch of this class as it happens.
- `cp` remains outside the mutation-verb list (pre-existing posture: best-effort
  denylist, ADR-0010); the carve-out removes the incentive to reach for it.

## Status

active

_Status: superseded by 0040_
