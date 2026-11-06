# Per-persona horsepower binds at dispatch, not at agent registration

Field report (2026-07-14): every dispatch in a live run inherited the parent session's
flagship model (Fable 5) despite the compiled persona definitions declaring
haiku/sonnet/opus tiers. The router's own post-hoc rationale ("conservative judgment
call") was partly confabulated: the mechanism never gave it the tier default to begin
with. The 0.8.9 `model_mix` journaling is what made the drift visible.

Root cause is a confirmed harness bug, not (only) router behavior: Claude Code ignores an
agent definition's `model:` frontmatter entirely — subagents inherit the parent model
unless the caller passes `model` on the dispatch call itself (issues #44385 / #43869,
open since April 2026, no fix ETA). The documented resolution order (env var → dispatch
param → frontmatter → parent) does not match reality; only the dispatch param works.
`effort:` frontmatter appears to bind. This voids §2a′'s premise that "the static default
is the load-bearing choice — it can't be forgotten": the harness forgets it wholesale.

**Decision.** The tier contract stays in `agents.yaml` (source of truth), but the router
**carries it into every dispatch explicitly**: pass the persona's model + effort on the
dispatch call, journal exactly what was passed (`dispatched` `model`/`effort`), and audit
via `metrics model_mix`. Two behavioral rules ride along in §2a′, both from the same field
report: **escalation must name the sharp item** (blanket "correctness-critical platform"
inherit-up is the measured anti-pattern), and **batch by tier** (a dispatch runs at its
hardest item's tier, so mechanical work must not be bundled with sharp work).

## Considered options

- **Rely on frontmatter and wait for the upstream fix** — rejected: the bug is 3+ months
  old with no ETA, and the cost is 5-30x per dispatch. Explicit-at-dispatch also remains
  correct post-fix (the dispatch param outranks frontmatter by design).
- **`CLAUDE_CODE_SUBAGENT_MODEL` env var** — rejected: session-global (one model for all
  personas defeats per-role tiers) and hostile environments hardcode it (#47488).
- **Codex/opencode parity check** — no change needed: `dispatch-persona.sh` already passes
  the per-role model/effort from the compiled `.toml` on each `codex exec` (ADR-0017), so
  explicit-at-dispatch was already the Codex mechanism; this aligns Claude Code with it.

## Consequences

- SKILL §2a′ carries the concrete persona→model/effort table and the two behavioral rules;
  §3a orders the explicit pass + journal. KNOWN-LIMITATIONS documents the harness bug.
- The compiled `model:` frontmatter stays (harmless, correct if the bug is fixed, and other
  harnesses may honor it), but nothing relies on it.
- Costs shift from "silently flagship" to "tier by default, escalation visible in
  model_mix" — the operator can audit right-sizing per run (0.8.9 feature).

## Amended by ADR-0041

Frontmatter binds on current Claude Code, upward as well as down, so the agent
files are the default again. Premium personas carry no model and inherit the
main loop; the per-dispatch `model` is now the clamp that holds standard and
economy at or below the main loop, and the lever for a journaled override, not
a restatement of the agent file on every call.

## Status

active
