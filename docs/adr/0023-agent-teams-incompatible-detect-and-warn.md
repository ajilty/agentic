# Agent teams is incompatible with orchestrate's isolation; detect and warn (no opt-out)

Claude Code's experimental "agent teams" (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, off by
default) coordinates multiple sessions as peer-messaging teammates with a shared task list
and `SendMessage`. Field report: in a repo with agent teams enabled, dispatched subagents
behaved as chatty teammates — peer-messaging, relaying a "halt" signal, `@name` messages,
"Teammate finished" — the exact behavior orchestrate's model exists to prevent.

This directly contradicts ADR-0012 (capability-subtracted subagents, **not** agent-teams
teammates) and the disk-first control model (§0/§10): orchestrate assumes a dispatched
persona is isolated, returns its result via disk, and cannot inject a control action. Agent
teams re-enables peer-messaging at the harness level, below the plugin.

What was verified (claude-code-guide + docs, 2026-07-06):
- Enabled solely by `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (env or `settings.json`), off by default.
- Whether it captures a plugin's `Task`-dispatched subagents is **undocumented**; the field
  observation strongly indicates it does.
- The state is reliably **detectable**: the env var, or `~/.claude/teams/`.
- There is **no plugin opt-out**: no per-dispatch flag and no settings key to force isolated,
  non-teammate subagents.

**Decision.** Since orchestrate cannot force isolation, it detects and warns, and documents the
incompatibility:
- A `SessionStart(startup|resume)` hook, `warn-agent-teams.sh`, warns when the env var is set:
  orchestrate's guarantees are unverified under agent teams; disable it for the repo. It is a
  **warning, not a hard block** — running under teams is the operator's risk call (the ADR-0002
  posture: the operator owns residual risk). Claude-Code-only (the var is unset on Codex/OpenCode,
  so the hook is a silent no-op there).
- A KNOWN-LIMITATIONS entry classifies this as a harness behavior orchestrate cannot compensate
  for, only surface.

## Considered options
- **Hard-block (refuse to dispatch under agent teams)** — rejected: too paternalistic; the
  operator may knowingly accept the weakened guarantees, and a hard stop would strand a
  legitimate run. A loud warning + docs is proportionate; the risk tolerance is the operator's.
- **Declare the hook in `agents.yaml`** (the harness-neutral contract) — rejected: agent teams is
  a Claude-Code-only concept; the warn hook is wired directly in the Claude Code `hooks.json` and
  is a no-op elsewhere. The neutral floor stays free of one harness's vocabulary.
- **File upstream for a per-dispatch isolation flag** — the only real fix, but it is Anthropic's
  to build; noted for a `/feedback` ask, out of scope for the plugin.

## Consequences
- New `warn-agent-teams.sh` + `hooks.json` SessionStart wiring; KNOWN-LIMITATIONS entry; covered
  by `test_hooks_safety.sh` (env set → warns; unset → silent). No `agents.yaml` change (Claude-only).
- With agent teams on, orchestrate's guarantees are advisory; the warning makes that explicit
  rather than letting a compromised run look safe. Complements ADR-0012 by naming the one harness
  setting that voids its premise.

## Status

active

_Status: superseded by 0040_
