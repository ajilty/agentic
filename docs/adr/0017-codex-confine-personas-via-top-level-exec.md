# Confine Codex personas with a top-level `codex exec --cd`, not in-session `spawn_agent`

ADR-0016 concluded that on Codex the per-persona PreToolUse hook floor is a main-agent
floor (it does not fire inside a spawned subagent), and stated that a spawned persona's
confinement therefore "rests on its role `sandbox_mode` + capability subtraction." A
later live-probe pass (the "is it really unfixable?" question) found that second half is
**wrong**, and that the gap is fixable. This ADR records the correction and the fix.

What the live probes established (codex-cli 0.142.x, `codex exec` headless):

- A `spawn_agent`-spawned subagent **is** confined by the **session** OS sandbox: a write
  to a read-only path (`.git/`) is blocked at the syscall (`read-only file system`); a
  write to a writable path (`src/`) succeeds. So a spawned persona is not unconstrained,
  but in `workspace-write` it **can still write source** — it is not lane-confined.
- `spawn_agent` has **no per-agent sandbox parameter** (`task_name`/`task`/`model`/
  `fork_turns` only) and its contract is "all agents share the same container and
  filesystem as you." So the per-role `sandbox_mode` the installer writes into
  `agents/*.toml` is **inert for a spawn** — it does not re-sandbox the subagent. The
  ADR-0016 / KNOWN-LIMITATIONS claim that role `sandbox_mode` confines a spawn is false.
- `writable_roots` is **additive** (it adds writable dirs to `[workdir, /tmp, …]`, never
  subtracts source) and is **ignored entirely in `read-only` mode**. So "read-only + add
  back the results dir" does not work, and `writable_roots` cannot narrow a persona to its
  lane.
- Under `workspace-write`, the writable root is the **cwd subtree**, not the git root.
  With `codex exec --cd <results-dir>`, writes to that subtree succeed while writes to the
  repo root and `src/` are OS-blocked and the repo stays readable.
- The main-agent PreToolUse floor (write-scope, deny-heldout-read, gates) **fires for a
  top-level `codex exec`** and hook-trust is already auto-seeded (ADR-0016).
- No other hook event fires for an in-session spawned subagent's tool calls (PreToolUse
  doesn't; SubagentStart is inert headless). The lever is the OS sandbox, not a hook.

**Decision.** Confine the read-only personas on Codex by dispatching each as its **own
top-level `codex exec` session whose cwd is its result directory**, rather than as an
in-session `spawn_agent`:

| Persona | Launch | OS effect |
|---|---|---|
| researcher | `codex exec -s workspace-write --cd <ticket>/findings/_quarantine` | writes confined to that subtree; source/prod/other-lane OS-blocked; repo readable |
| verifier | `codex exec -s workspace-write --cd <ticket>/verdicts` | same |
| planner | `codex exec -s workspace-write --cd <ticket>` (keep spec/ADR under the ticket dir) | same |
| implementer | `codex exec -s workspace-write --cd <repo root>` | source writable by design |
| actuator | `codex exec -s read-only` | no file writes (mutates live state via run) |

This is OS-enforced (syscall-level `read-only file system`), survives any sub-spawn, does
not depend on hook-trust, and the main-agent hook floor still fires on top as
defense-in-depth and for finer lane separation. It is strictly stronger than the
Claude-Code hook floor for these personas. It fits the disk-first read lane (ADR-0014):
a persona is already a separate process that writes its result to a known path and the
router reads it from disk, so per-persona top-level dispatch is a natural fit, not a
contortion. Claude Code is unaffected — there PreToolUse fires for subagent tool calls,
so the native per-persona hook floor stands.

## Considered options
- **In-session `spawn_agent` + per-role `sandbox_mode`** — rejected: `sandbox_mode` is
  inert for a spawn; one session is one sandbox + one cwd for every agent it spawns, so
  per-persona confinement is impossible in-session.
- **`writable_roots` narrowing** — rejected: additive, never subtractive; ignored in
  read-only mode.
- **A different hook event for spawned tool calls** — none found.
- **v2 `[permissions]` profile** (per-path read/write rules) — schema exists but did not
  validate in-session and is not shown to re-sandbox a spawn; not relied upon. Revisit if
  it stabilizes (could give finer-than-cwd lane separation).

## Consequences
- **Implemented (0.8.0).** `runtime/dispatch-persona.sh` runs each persona as
  `codex exec -s <sandbox> --cd <lane>`; `install-codex.sh` emits it, writes the per-persona
  bodies it injects, and appends a dispatch addendum to the Codex brain telling the router
  to use it instead of `spawn_agent`. **Requires the router session's `network_access = true`**
  (the installer sets it in `config.toml`) so the nested persona `codex exec` can reach the
  model — without it the launcher cannot dispatch. This brings Codex to Claude Code's
  existing network-open posture; persona writes stay OS-confined by `--cd` regardless.
  Validated live: a launcher-dispatched verifier's out-of-lane write is refused
  (`read-only file system`), end-to-end through the launcher
  (`tests/integration/test_codex_persona_confine.sh`).
- Cost: the router shells out per persona on Codex and gives up Codex's native in-session
  `spawn_agent` context-forking. orchestrate does not rely on that (it passes explicit
  prompts and reads results from disk), so the loss is small.
- Nuance to design: the planner writes both the spec/ADR and ticket artifacts. Keep spec
  output under the ticket dir so one `--cd <ticket_dir>` covers it; otherwise run planner
  at repo-root and accept hook-floor-only (weaker) confinement for the spec path.
- Corrects KNOWN-LIMITATIONS rows 5/6 and ADR-0016: `writable_roots` cannot narrow, and
  per-role `sandbox_mode` does not confine a `spawn_agent` spawn. Until the fix ships, a
  spawned persona on Codex is confined only by the shared session sandbox (source writable
  in `workspace-write`) plus capability subtraction — it is **not** lane-confined.

## Status

active (implemented in 0.8.0)

_Status: superseded by 0040_
