# orchestrate — backlog (open items)

What to pick up next, captured so we don't lose the thread. Updated for 0.9.0
(2026-11-06), which removed the workflow-enforcing hooks, leases, and helpers
(ADR-0040); items about them are closed at the end of this file. The plugin is
published via the repo's self-marketplace. Tests: `tests/run.sh` (zero-dep; the
yaml-parsing checks need mikefarah yq v4 and self-skip on any other yq flavor)
and `tests/integration/run.sh` (real-CLI / live-agent, FS-isolated, gated).

## Process lesson — do this every batch (not optional)

**Run a fresh-context, whole-range review before calling any batch "done."** It has
caught a **Critical three times** during this build — each a cross-cutting or
runtime bug that inline self-review *and* the green unit suite missed:

- P1 — `lease-release` was wired nowhere (dead half of a lifecycle).
- P3 — the pre-apply gate was bound to `SubagentStart`, a *non-blocking* event, so
  it enforced nothing on Claude Code / Codex.
- P2 — `adr.sh reindex` aborted under `set -e` on body-prose "supersede" and
  truncated the index — **green in tests, broken on the real repo.**

Inline implementation is fast and fine; the adversarial whole-view pass is the
gate. This mirrors the skill's own thesis (an independent fresh-context
Verifier), validated on its own construction.

## High priority

- **Codex command parity (still open).** The Claude Code plugin ships
  `/orchestrate:{init,status,feedback}` and the OpenCode installer emits
  `/orchestrate-{init,status,feedback}`; Codex has no typed entry point yet. Add
  a Codex prompt (`~/.codex/prompts/orchestrate.md`) so the entry point works
  everywhere. (`SKILL.md` is already the shared brain; these are thin wrappers.)

- **Watch the clarify step in the field.** A live run on 2026-07-02 (`Improve the
  logging in this repo.`, headless sonnet router) skipped clarification: no
  `clarify` event, and the Planner invented its own acceptance script. The
  candidate fix then was a new gate; ADR-0040 rules that out without fresh
  evidence. Track it through run reviews instead: a lane with neither a
  `clarify` event nor a pre-existing oracle is the signal to look for.

## Medium

- **Subagent instances must be well-named (descriptive, consistent pattern) —
  especially under Claude Code; never the generic `general-purpose`.** Every
  dispatched subagent should carry a clear, consistent label/type so the operator
  can tell at a glance which lane/persona is running (e.g. `orchestrate:researcher`,
  `verify:test-suite`) rather than an opaque `general-purpose`. The plugin's five
  personas are already named; this convention must also cover any helper/verification
  dispatches the loop or its tooling spawns. Define the naming pattern and apply it
  wherever the router (or supporting scripts/workflows) dispatches a subagent.

- ✅ **DONE (0.8.6, spec `docs/specs/2026-07-02-orchestrate-status-command-design.md`) —
  standard `/orchestrate:status` command.** Read-only projection over reground +
  board + metrics: goal/pace headline, lane tree, conditional needs-you, next; renders
  per-lane model/effort (0.8.9) and the clean-boundary compaction nudge (0.8.10).
  Codex/OpenCode mirror still follows the command-parity item. Original spec:
  a slash command (sibling to `/orchestrate:init`) that
  prints the current work-board at a glance *without dispatching or advancing any
  lane*: open lanes + their persona/column, in-flight writer(s), halted
  `DECISION_FORK`s / quarantines awaiting the operator, held leases, and anything
  needing an ack/decision. Build on the existing `ledger.sh reground` + `board.jsonl`
  primitives (read-only view, not the full loop). **Rationale:** the operator runs
  many things at once and may have long gaps between check-ins — today re-grounding
  means running the loop or reading the ledger by hand; a one-shot status view lets
  them re-orient instantly. Mirror to Codex/OpenCode per the command-parity item.

## Low

- **`adr.sh` `add` / `reindex` double-maintenance.** `add` appends an INDEX row
  incrementally *and* `reindex` rebuilds from files; harmless when they agree, but
  the index header differs by which ran last. Optionally make `add` call `reindex`
  so there's a single index-maintenance path ("files are source of truth").
- **Generated vs hand-authored ADR body format.** `adr.sh add` writes
  `_Status: active_`; hand-authored ADRs use `## Status` / no status line. Cosmetic
  (supersede/reindex key on the status line, not the format), but worth aligning.

## Plugin-validation follow-ups (Task 8, 2026-06-18)

- ✅ **DONE — stale `scripts/install-<harness>.sh` refs in internal comments fixed.**
  Persona bodies (`references/personas/*.md`) and `references/agents.yaml` now say
  "the per-harness generators (build.sh / install-*.sh)" instead of a nonexistent
  install script; `agents/` rebuilt so the compiled prompts match (drift green).

## Testing coverage (tiers)

**Tier 1, zero-dep bash suite** (`tests/run.sh`, CI). Runtime logic (ledger
append, goal, retries, metrics, feedback, conformance, reground, legacy 0.8.x
boards); the two hooks (shared-checkout floor, compaction handoff, hook-safety
floor); generation and contract (allowlist, drift, hooks.json, manifest);
reference integrity (`test_integrity.sh`); and installer smoke for Codex and
OpenCode (`test_install.sh`: skill and persona definitions, no hook wiring).
Hermetic, no `claude`/API.

**Tiers 2 and 3, integration suite** (`tests/integration/run.sh`; not on the
per-push gate; self-skips without `claude`/auth). Filesystem-isolated at the
**HOME + cwd** level, never via harness config knobs (CLAUDE_CONFIG_DIR/--scope
only redirect user config, so a `claude` run inside a project still writes a
project-scope `.claude/`):

- **Tier 2 plugin-install smoke** (`test_plugin_install.sh`): real `claude` CLI
  validate, marketplace add, install, details inventory. Sandboxed HOME, no API.
- **Tier 3a mechanical invocation** (`test_invocation.sh`): live dispatch of the
  actuator, its Bash lane works, and its allowlist excludes Write/Edit.
- **Tier 3 writer lane** (`test_writer_lane.sh`): dispatches a real implementer
  with native `isolation: worktree`, and asserts the commit landed on a
  `worktree-*` branch and the primary checkout is untouched.

A containerized variant (Docker + pinned `claude` + version matrix) is a future
hardening for fully-hermetic CI of Tiers 2/3; the local FS-isolated form is the
current vehicle. Live tiers need OAuth (real ~/.claude) or `ANTHROPIC_API_KEY`.

Not yet built:

- **Effectiveness A/B eval (Tier 3c).** Golden fixtures {seed, goal, held-out
  oracle, safety invariants} run through the pattern vs a naive single-agent baseline;
  score outcomes vs the oracle and count safety violations. Safety = hard gate,
  quality = threshold/trend. Heaviest; needs fixture format + scoring runner + baseline.

- ✅ **RESOLVED/WATCH — Issue B (`orchestrate:*` agents don't survive resume/reload).**
  Not reproducible on CC 2.1.186: interactive probe returns RESEARCHER_OK on fresh +
  post-`/exit` + resumed sessions, `/reload-plugins` shows the full 21 agents (no drop);
  headless suite passes. Likely a since-fixed harness bug or transient. Runbook retained
  to re-verify if it recurs. Original investigation below (kept for context):
  Observed (CC 2.1.x, interactive): the plugin's five agents register only at the
  first session-start after install; on resume they drop ("no longer available"), and
  `/reload-plugins` reloads skills+hooks but NOT agents (deltas 21→16 agents, 11→10
  plugins — the −5 are the personas). `subagent_type: orchestrate:researcher` → "not
  found" on resume.
  **INVESTIGATED (2026-06-23) — narrowed to the interactive harness, NOT the plugin.**
  Built `tests/integration/test_resume_registration.sh` (installed plugin in a
  credential-cloned sandbox HOME → `claude -p` session 1 → `claude -p -c` resume →
  dispatch `orchestrate:researcher`). Result: resume **kept** the agent dispatchable
  (RESEARCHER_OK both sessions); a stale `enabledPlugins:{orchestrate@ghost}` entry did
  **not** break the real install/load. So it does NOT reproduce headlessly — because
  each `claude -p` is a fresh process that re-initialises plugins and re-registers
  agents every time. That rules out the plugin artifacts/config and stale-enable as the
  cause and pins Issue B to the **interactive `--resume`/`--continue` TUI path** —
  agent-types register at interactive session-start and interactive resume doesn't
  re-run that step. **Likely a CC harness limitation, not an orchestrate fix.** Open:
  (a) confirm via claude-code-guide whether explicit agent enumeration in plugin.json
  (vs auto-discovery) changes interactive-resume registration, and whether
  `/reload-plugins` is meant to re-register agents; (b) the minimal operator step
  (a fresh interactive session re-registers — their evidence #1; `/reload-plugins` did
  not) — verify interactively by an actual dispatch (can't be done headlessly).
  **Interactive verification runbook (probes + results table):**
  `docs/issue-b-resume-registration-verification.md`.

## Agent teams (CC): deliberately not used (ADR-0012)

CC's experimental "agent teams" (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
coordinates full teammate *sessions* that message each other, which bypasses
orchestrate's isolated dispatch-and-return model where disk is the only channel.
Plain subagent dispatch needs no flag (verified). We stay subagent-based; the
flag is intentionally absent from install/test settings. A teams-based variant
would need its own design; see `docs/adr/0012-subagents-not-agent-teams.md`.

## Watch (acceptable as-is, but depends on loop discipline)

- **`decision` event + ADR capture are router loop-steps, not hooks.** Like
  `returned`/`verdict`, they're appended by the router as it drives (now real
  callables: `ledger.sh decision`, `adr.sh add`), not enforced by a hook — because
  fork-resolution is operator-interactive. Acceptable, but if judgment memory ever
  fails to accumulate, this is the first place to look (the router skipped the step).

## Out of scope (plugin packaging v1 — deferred, spec §2)

- **Other-harness plugin manifests** (`.codex-plugin`, `.cursor-plugin`,
  `gemini-extension.json`, `.opencode`). Their schemas are unverified against
  current docs; Codex/OpenCode keep their existing `install-*.sh` installers
  untouched (ADR-0001 compile-per-harness model stays per harness).
- **Seed-dir / container / managed-image rollout** (`CLAUDE_CODE_PLUGIN_SEED_DIR`).
- **Official-directory submission** to `anthropics/claude-plugins-official`.

## Not skill work (operational)

- The orchestrate plugin is merged to `main` and pushed to `origin`
  (github.com/ajilty/agentic); installable in any repo via
  `/plugin marketplace add ajilty/agentic` then
  `/plugin install orchestrate@ajilty`.

## Closed by ADR-0040 (0.9.0)

Each item below concerned a hook, lease, or helper that 0.9.0 removed. Resolved
by ADR-0040 (removed); the history is in git and the ADR.

- **Enforcement is self-disarmable** (agents could edit the plugin's hook
  scripts). No new gate is added to protect the one remaining floor; the live
  testing note in KNOWN-LIMITATIONS still applies.
- **`keep-on-branch.sh` false-denied worktree commits under CC.** Fixed in
  0.8.x, then removed with the branch guard.
- **Hooks read CC's stdin JSON; per-dispatch context via the active-writer
  record.** The surviving floor still reads stdin and resolves from the
  payload's `cwd`; the active-writer record is gone.
- **run-scope blocked verifier scratch rehearsals.** run-scope is removed; the
  verifier's brief says to rehearse in scratch or a detached copy.
- **`reground` halts on a dangling `active-writer.json`**, the overwrite test
  for `writer-ctx set`, and the unread active-writer `persona` field.
- **Portable hook paths for Codex/OpenCode installers.** Those installers wire
  no hooks.
- **Lease acquire atomicity (TOCTOU)**, **`TARGETS` comma-split**, and
  **lease-key JSON escaping.** Leases and the write-ahead hook are removed;
  shared-target steps run one at a time by router guidance.
- **Write-ahead moved from `SubagentStart` to PreToolUse on dispatch
  (ADR-0011).** The router journals `dispatched` itself before every dispatch.
- **Tier 3b safety eval of the pre-apply gate** (`test_safety_gate.sh`). The
  gate is removed; a production change is a confirmation with the operator.
