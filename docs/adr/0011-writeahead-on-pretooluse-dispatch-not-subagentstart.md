# Writer write-ahead fires on PreToolUse of the dispatch tool, not SubagentStart

The writer write-ahead (`on-writer-dispatch.sh`: deterministically append the
`dispatched` event + take the lease BEFORE a writer runs, so a just-dispatched
writer that left no dirty worktree is still visible to `reground`) was wired to the
Claude Code `SubagentStart` hook event. Live testing (CC 2.1.186, `claude
--plugin-dir … --debug`) confirmed **SubagentStart does not fire** — so under the
plugin the write-ahead never ran (green in unit tests, dead on the real harness).

**Decision.** Wire the write-ahead to **`PreToolUse` matching the dispatch tool
(`Task|Agent`)** — it fires when the *router* dispatches a writer, which is before the
writer runs. The dispatched persona arrives as `tool_input.subagent_type` (the
dispatching parent's own `agent_type` is null); it is plugin-namespaced
(`orchestrate:implementer`) and stripped like every other persona match. The
ticket / assigned-branch / prod-targets are read from the on-disk **active-writer
record** (ADR-0006), since CC passes no router-set per-dispatch env to hooks. As a
PreToolUse hook it must never block the dispatch: ledger side-effects only, always
exit 0.

## Considered options
- **Keep SubagentStart** — dead under CC; the write-ahead silently never runs.
- **Router does the write-ahead in-loop** — works, but relies on loop/prompt
  discipline; the deterministic-rail thesis prefers a hook on an event that fires.
  (The dispatch-tool PreToolUse hook IS that event.)

## Consequences
- One script serves all harnesses: `on-writer-dispatch.sh` detects the persona from
  `tool_input.subagent_type` (CC PreToolUse-on-dispatch) OR `agent_type` OR `PERSONA`
  env (Codex/OpenCode subagent-start). Codex/OpenCode keep their subagent-start
  wiring pending per-harness confirmation.
- Verified by an actual live dispatch: the `dispatched` event + lease are journaled
  on CC. Locked by unit tests feeding the `subagent_type` dispatch payload.
- Extends ADR-0006: the active-writer record is now also the write-ahead's source for
  branch/targets, not just the gate/branch hooks.

## Status

active

_Status: superseded by 0040_
