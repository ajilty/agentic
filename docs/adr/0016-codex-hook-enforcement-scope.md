# Codex enforces fail-closed hooks for the MAIN agent's hooked tools, not for spawned subagents or apply_patch

> **Correction (ADR-0017).** This ADR states below that a spawned persona's confinement
> "rests on its role `sandbox_mode` + capability subtraction." A later live probe found
> that is **wrong**: `spawn_agent` shares the session sandbox and exposes no per-agent
> sandbox knob, so the per-role `sandbox_mode` is **inert** for a spawn. A spawned persona
> is confined only by the shared session sandbox (source writable in `workspace-write`) +
> capability subtraction — it is not lane-confined. The fix (per-persona top-level
> `codex exec --cd`) is in **ADR-0017**. The apply_patch finding below was separately
> resolved in 0.7.1.

orchestrate's safety floor is a set of fail-closed PreToolUse hooks (held-out-read
denial, branch-keep, pre-apply gate, write-scope, run-scope). On Claude Code these
**block** a tool call by exiting non-zero with a stderr contract. The open question
for Codex was whether the same hooks are advisory (logged, ignored) or load-bearing
(actually deny the call), and over **which** tool calls they have reach.

A live probe (codex-cli 0.142.1, `codex exec` headless) gives a partial yes, and the
scope of that yes is the whole point of this ADR.

**Where the hooks enforce.** A wired PreToolUse hook on the **MAIN agent** blocks:
exit 2 plus a stderr message is honored, and the wire shape Codex hands the hook is
Claude-Code-shaped (`tool_name`, `tool_input.command`, the same JSON the hooks already
read). For the main agent's hooked tools, Codex enforcement is real, not advisory.

**Where the hooks do NOT enforce (the two gaps that bound the claim).**

1. **PreToolUse does not fire inside a spawned subagent.** A dispatched persona's own
   tool calls are **not** seen by the per-persona hooks (`write-scope`,
   `keep-on-branch`, `deny-heldout-read`). So a spawned persona's confinement does not
   rest on those hooks at all on Codex: it rests on the role's `sandbox_mode` plus
   capability subtraction (the persona's tool set and `agents.yaml` capabilities).
   This is the load-bearing correction: orchestrate's per-persona hook floor is a
   **main-agent** floor on Codex, not a per-subagent one.

2. **The `apply_patch` tool is not matched.** Codex's top-level writes surface as the
   `apply_patch` tool, but the PreToolUse matcher the installer wires is
   `^(Read|Edit|Write|Bash)$`, which does not match `apply_patch`. So even a
   **main-agent** write via `apply_patch` bypasses `write-scope` until the matcher is
   widened. Known installer follow-up.

So "full-guarantee parity" overstates it. The honest statement: **Codex enforces
fail-closed hooks for the main agent's hooked tools (verified: exit-2 deny honored),
but not for spawned-subagent tool calls (PreToolUse does not fire there) nor for the
`apply_patch` tool (matcher gap). Spawned-persona confinement on Codex relies on
`sandbox_mode` plus capability subtraction.** Claude Code, where PreToolUse fires for
subagent tool calls, retains the stronger per-persona hook floor.

## Other Codex behaviors found

- **Hook trust must be persisted.** A wired Codex hook silently NO-OPS (fails OPEN)
  unless its sha256 is recorded as trusted in `[hooks.state]`, or the session runs
  `--dangerously-bypass-hook-trust`. Inverse of Claude Code, where a referenced hook
  runs immediately. Until trust is persisted, even the main-agent floor is **inert**.
  The installer must write the per-hook trust entries at install time.

- **SubagentStart does not fire in `codex exec` headless.** So per-subagent model
  override via the `on-writer-dispatch` SubagentStart hook is **inert** headlessly.
  The role `.toml` `model` field sets the tier instead (verified working). This makes
  the `.toml` schema fix below the actual carrier of the per-persona tiers, not a
  nice-to-have.

- **Agent-role `.toml` schema is wrong for Codex.** The installer emits
  `name`/`description`/`sandbox_mode`/`mcp_servers`/`instructions`. Codex's schema is
  `developer_instructions` (not `instructions`) plus `model` and
  `model_reasoning_effort`. The tiers (agents.yaml `tier:`) are dropped today. The
  rewrite maps them: model `economy → gpt-5.4-mini`, `standard → gpt-5.4`,
  `premium → gpt-5.5`; effort `low/medium/high/xhigh`, with `max → xhigh` (Codex has
  no `max`, so the Verifier's max-effort lane degrades to `xhigh`).

- **Held-out `.command` read already fixed (0.6.1).** `deny-heldout-read.sh` inspects
  `tool_input.command`, denying a Writer reading the held-out oracle by shelling out
  (`cat`/`sed`) around the Read-tool path. Harness-neutral. Note that, per gap 1, this
  hook only covers the main agent on Codex; a spawned persona's shell reads are bounded
  by `sandbox_mode`, not this hook.

## Considered options

- **Claim full-guarantee parity.** Rejected by the probe: PreToolUse does not fire in
  spawned subagents and `apply_patch` is unmatched, so the per-persona hook floor is a
  main-agent floor on Codex. Claiming parity would misrepresent where a spawned
  persona's confinement actually comes from (`sandbox_mode` + capability subtraction).
- **Declare Codex advisory-only.** Also rejected: the main-agent hooks demonstrably
  block (exit-2 honored), so they are load-bearing for the tool calls they reach.
  "Advisory-only" understates that.
- **Fork the runtime hooks per harness.** Rejected. The wire shape is Claude-Code-shaped
  and the hooks read the same JSON unchanged; the Codex-specific work (trust, `.toml`
  schema, matcher width) is in the **installer**, not the hook bodies.
- **Leave hook trust to the operator / rely on `--dangerously-bypass-hook-trust`.**
  Rejected. A floor the operator must remember to arm is not fail-closed; the bypass
  flag defeats the trust model. The installer persists trust.

## Consequences

- The Codex enforcement story is **scoped, not full**: main-agent hooked tools are
  fail-closed; spawned-subagent tool calls and `apply_patch` are not. Spawned-persona
  confinement on Codex is carried by `sandbox_mode` + capability subtraction. Recorded
  in `plugins/orchestrate/KNOWN-LIMITATIONS.md`.
- Installer follow-ups: persist hook trust (else the floor is inert); rewrite the
  `.toml` schema to `developer_instructions`/`model`/`model_reasoning_effort` with the
  tier map (the carrier of per-persona tiers, since SubagentStart is inert headlessly);
  widen the PreToolUse matcher to include `apply_patch` so main-agent writes are scoped.
  The runtime hooks and the `agents.yaml` contract are unchanged.
- `sandbox_mode` on Codex is coarse (`workspace-write`); for the main agent, results-only
  confinement is carried by `write-scope.sh` and `writable_roots` can narrow it. For a
  spawned persona, `sandbox_mode` is the primary confinement (the hook does not fire).
- Actuator credential confinement stays **advisory** (ADR-0002) on every harness, Codex
  included. Unchanged.

## Status

active

_Status: superseded by 0040_
