# orchestrate — backlog (open items)

What to pick up next, captured so we don't lose the thread. As of 2026-06-22.
The orchestrate plugin (packaging + enforcement hooks) is merged to `main` and
published via the repo's self-marketplace. Tests: `tests/run.sh` (zero-dep; the
yaml-parsing checks need mikefarah yq v4 and self-skip on any other yq flavor)
+ `tests/integration/run.sh` (real-CLI / live-agent, FS-isolated, gated).

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
gate. This mirrors the skill's own thesis (single writer + independent
fresh-context Verifier) — validated on its own construction.

## High priority

- **§2b clarify gate silently passed a fuzzy goal (live 2026-07-02, sonnet router).**
  Real-world probe: `/orchestrate:init Improve the logging in this repo.` — no
  nameable acceptance oracle, headless session. Expected: `clarify inline` journaled
  + lane HALTed open. Observed: no `clarify` event; the Planner invented a spec AND
  its own acceptance script (`scripts/verify_logging.py` — a self-authored oracle,
  exactly the plausible-but-wrong-spec failure §2b exists to stop), and an
  Implementer lane started. Downstream rails held (worktree isolated, nothing
  merged, reground HALTs with OPEN WRITER + leases), but the front-door gate is
  pure loop discipline with no enforcement backstop and it missed on first live
  contact. Candidate fix: a done/merge-time floor (refuse to close a lane whose
  board has neither a `clarify` event nor a pre-existing oracle reference for the
  ticket), or a dispatch-time hook that blocks the first Planner dispatch when the
  work-item has no oracle and no clarify event. Needs design — the check "is an
  oracle nameable" is a judgment call; the floor can only key on journaled traces.

- **Enforcement is self-disarmable: agents can edit the plugin's own hook scripts
  (live 2026-07-02).** The runtime hooks execute from `${CLAUDE_PLUGIN_ROOT}`, which
  is writable by the router and by any full-write persona — observed live when a
  router patched `keep-on-branch.sh` mid-run to route around a false-deny (benign
  intent, real hole: the same move disarms any fail-closed floor, and no rail even
  notices). Candidate: a writer-scoped PreToolUse deny on Write/Edit/Bash targets
  resolving under `$CLAUDE_PLUGIN_ROOT`, self-exempting when the working repo IS the
  plugin repo (else it blocks legitimate plugin maintenance — the one case where
  editing hooks is the job). Needs the same care as write-scope: fail-closed on an
  unresolvable path, never break the session. Until then it is a documented
  trust-the-router posture (KNOWN-LIMITATIONS "testing live" §2).

- ✅ **DONE (live 2026-07-02) — `keep-on-branch.sh` false-denied every legitimate
  worktree commit under CC.** The off-branch-commit check ran `git rev-parse` in the
  hook process's own cwd — which under CC is the main checkout, not the subagent
  shell's worktree — so with `ASSIGNED_BRANCH` set (writer-ctx, ADR-0006) it saw
  `master`, denied all four commit attempts of a live implementer, and in a parallel
  lane likely caused the `REJECTED(uncommitted-work)` verdict (the ADR-0019 backstop
  caught what the broken rail blocked). Fix: resolve the branch at the EFFECTIVE
  commit dir (`git -C <dir>` > last `cd <dir>` in the compound command > payload
  `.cwd` > hook cwd), fail-closed on mismatch; regression tests cover cd-compound,
  `git -C`, and the rogue main-checkout commit. Found only by live testing — the
  unit tests ran the hook with cwd already inside a worktree.

- ✅ **DONE — Hooks read CC's stdin JSON (not env); PreToolUse enforcement is REAL
  under CC.** Landed part-1 (03a3ced, stdin parse) + part-2 (40bcf5b, ADR-0006
  on-disk active-writer record); the live smoke test (2026-06-19) confirmed all 3
  PreToolUse hooks fire on a dispatched writer's Bash call. _Original problem (kept
  for history):_ CC delivers
  the hook payload on **stdin** (`tool_name`, `tool_input`, `session_id`, `cwd`,
  and inside a subagent `agent_id`/`agent_type`). There is **no `CLAUDE_AGENT_TYPE`
  env var** (only `$CLAUDE_EFFORT`). Our hooks read `PERSONA`/`RESOLVED_PATH`/
  `TOOL_INPUT` env, which CC never sets → the PreToolUse hooks (held-out,
  branch-guard, prod-gate) always hit the "not a writer" path and **allow** — they
  no-op under CC (safe, but not enforcing). Fix: parse stdin JSON
  (`agent_type` for persona, `tool_input.command` for Bash, `tool_input.file_path`
  for Read), keeping the env reads as the Codex/OpenCode fallback. Match
  `agent_type` against the agent's frontmatter `name`.
  - **Per-dispatch context is the harder half (ADR-worthy).** The prod-gate needs
    `PROD_TARGETS` and branch-guard needs `ASSIGNED_BRANCH` *per dispatch* — set by
    the router as env, but CC subagent hooks receive only the stdin payload, not
    router-set env. So the hooks must read orchestrate's **on-disk artifacts**
    (the ticket spec's `mutation_targets`/`consequence`, the assigned branch)
    keyed by `agent_id`/`cwd` — "disk is the source of truth" applied to the hook
    layer. With this: held-out works once stdin-parsed (HELDOUT_ROOT is
    session-global); gate + off-branch-commit need the disk lookup.
  - **Still holds regardless of the hook layer:** capability allowlists (native CC
    per-agent `tools:`) and the filesystem held-out isolation — the load-bearing
    guarantees never depended on these hooks.
  - History: the env-var assumption first crashed the session (bare `${VAR:?}`),
    then (after the exit-code fix) was found to silently no-op. The generalized
    `test_hooks_safety.sh` floor catches the crash class; making enforcement real
    needs the stdin-parse + disk-lookup above.

- **run-scope hook blocks legitimate verifier scratch rehearsals (live 2026-07-14).**
  Two fresh-context verifiers reported the run-scope floor denied their rehearsal
  attempts: one stubbed-aws rehearsal fell back to static analysis (weaker than a
  function-proof — the ADR-0022 bar), another had to assemble its result sentinel via
  `chr(62)` to get past matching. Verification quality degrades exactly where the
  safety mechanism lives. Candidate fix: a scratch carve-out in `run-scope.sh` (allow
  mutations confined to the session scratchpad / a rehearsal tmpdir, deny everything
  else as today), or a dedicated rehearsal lane shape for verifications that need to
  execute. Needs the same fail-closed care as write-scope: an unresolvable path denies.

- **Codex / OpenCode command parity (still open).** The Claude Code plugin ships
  `commands/init.md` → `/orchestrate:init`; the other two harnesses don't yet.
  Add a Codex prompt (`~/.codex/prompts/orchestrate.md`) and an OpenCode command
  so the typed entry point works everywhere. (`SKILL.md` is already the shared
  brain; these are thin wrappers.)

## Part-2 follow-ups (verifier-flagged)

- ✅ **DONE — `reground` HALTs on a dangling `active-writer.json`.** reground block
  (d) surfaces a leftover record (router crashed between `writer-ctx set` and
  `clear`) as an ambiguous in-flight writer → HALT (exit 3); the operator/router
  clears it on reconcile. Chose HALT over auto-clear because at compaction the
  record may belong to a live writer. Closes the stale-ack gate-bypass window.
- ✅ **DONE — overwrite test** for `writer-ctx set` (the per-dispatch refresh).
- ✅ **DONE (ADR-0039) — the persona is now the record's file name**
  (`active-writer.<persona>.json`), so each hook reads only its own persona's
  record; the in-file `persona` field stays for display only.

## Medium

- ✅ **DONE — portable hook paths (Claude Code).** The plugin auto-registers hooks
  via `hooks/hooks.json` with `${CLAUDE_PLUGIN_ROOT}`-relative commands — machine-
  independent and committed, no `settings.json`/`settings.local.json` snippet to
  paste. The Codex/OpenCode installers still print absolute paths in their config
  snippets (their `${...}` equivalents remain a follow-up for those harnesses).


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

- **Lease acquire atomicity (TOCTOU).** `ledger.sh lease-acquire` is
  check-then-write; two concurrent acquires of a free target could both win.
  Replace with an atomic claim (`mkdir` lockdir, or `set -C`/noclobber `O_EXCL`).
  **Required before lifting "single router per repo"** (SKILL §15) — today the
  single-router + lease-check-before-dispatch model makes the window unreachable,
  which is why it's deferred, not fixed.

## Low (deferred-with-ticket from the P1 whole-branch review)

- **`TARGETS` comma-split.** `on-writer-dispatch.sh` word-splits on whitespace
  only, but the interface doc said "space- or comma-separated." Normalize
  (`tr ',' ' '`) or pin the contract to space-only — **do it when the router
  emitter that populates `TARGETS` lands**, so both ends agree. Currently
  unreachable (nothing emits `TARGETS` yet).
- **Lease-key JSON escaping.** Lease files and the `gate-blocked`/`lease-conflict`/
  `decision` events embed `$key` via unescaped `printf`. Safe for the
  `<kind>:<scope>` charset today; add escaping (or reject out-of-charset keys at
  the boundary) **only if keys ever become free-form/user-supplied.**
- **`adr.sh` `add` / `reindex` double-maintenance.** `add` appends an INDEX row
  incrementally *and* `reindex` rebuilds from files; harmless when they agree, but
  the index header differs by which ran last. Optionally make `add` call `reindex`
  so there's a single index-maintenance path ("files are source of truth").
- **Generated vs hand-authored ADR body format.** `adr.sh add` writes
  `_Status: active_`; hand-authored ADRs use `## Status` / no status line. Cosmetic
  (supersede/reindex key on the status line, not the format), but worth aligning.

## Plugin-validation follow-ups (Task 8, 2026-06-18)

- ✅ **FIXED (ADR-0011) — `SubagentStart` doesn't fire under CC; write-ahead moved to
  PreToolUse on the dispatch tool.** Confirmed live (CC 2.1.181/2.1.186): SubagentStart
  never appears; the write-ahead now runs as `PreToolUse` matcher `Task|Agent` (fires
  when the router dispatches a writer), reads the dispatched persona from
  `tool_input.subagent_type` (namespace-stripped), and branch/ticket/targets from the
  on-disk active-writer record (ADR-0006). Proven end-to-end by a live dispatch: the
  `dispatched` event + lease are journaled. Locked by unit tests (subagent_type payload)
  + drift/contract-parity. Codex/OpenCode keep their subagent-start wiring (per-harness,
  unconfirmed); `on-writer-dispatch.sh` self-detects persona from subagent_type OR
  agent_type OR env so one script serves all.
- ✅ **DONE — stale `scripts/install-<harness>.sh` refs in internal comments fixed.**
  Persona bodies (`references/personas/*.md`) and `references/agents.yaml` now say
  "the per-harness generators (build.sh / install-*.sh)" instead of a nonexistent
  install script; `agents/` rebuilt so the compiled prompts match (drift green).

## Testing coverage (tiers)

**Tier 1 — zero-dep bash suite** (`tests/run.sh`, 176/176, CI). Runtime logic (A);
generation/contract — allowlist, drift, hook-path, contract-parity, manifest (B);
dependency/reference integrity — persona `body:` existence + SKILL/persona nav-ref
resolution (`test_integrity.sh`); installer smoke — all 5 personas + codex
sandbox_mode mapping (`test_install.sh`); and the namespaced-persona regression
(`test_hooks_safety.sh`). Hermetic, no `claude`/API.

**Tiers 2 + 3 — integration suite** (`tests/integration/run.sh`; NOT on the per-push
gate; self-skips without `claude`/auth). Filesystem-isolated at the **HOME + cwd**
level — never via harness config knobs (CLAUDE_CONFIG_DIR/--scope only redirect user
config, so a `claude` run inside a project still writes a project-scope `.claude/`):
- **Tier 2 plugin-install smoke** (`test_plugin_install.sh`) — real `claude` CLI:
  validate + marketplace add + install + details inventory. Sandboxed HOME, no API.
- **Tier 3a mechanical invocation** (`test_invocation.sh`) — live dispatch: actuator
  dispatched, Bash lane works, allowlist excludes Write/Edit, SubagentStart sentinel.
- **Tier 3b safety eval** (`test_safety_gate.sh`) — live: the pre-apply gate blocks a
  real actuator prod mutation (hard-gate; skips on model-decline). **This eval caught
  the namespaced-`agent_type` bug** that left ALL hook enforcement hollow under the
  plugin (now fixed — git 355c153).
- **Tier 3 writer-lane** (`test_writer_lane.sh`) — live, the proactive catch for the
  harness-path class: on the stale-default-branch topology (origin/HEAD→stale master,
  blank-slate current), helper-create the worktree → dispatch a real implementer to
  work IN it (cd, not isolation:worktree) → commit to its worktree-agent-* branch →
  merge clean. Asserts right base (current, not origin/HEAD), §9b branch, clean merge,
  and shared checkout untouched. The test the worktree field failures kept slipping past.

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

## Agent teams (CC) — deliberately NOT used (ADR-0012)

CC's experimental "agent teams" (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) coordinates
full teammate *sessions*, which would bypass orchestrate's subagent-scoped guarantees
(capability subtraction + fail-closed hooks). Plain subagent dispatch needs no flag
(verified). We stay subagent-based; the flag is intentionally absent from install/test
settings. A teams-based variant would require re-establishing the guarantees first —
see `docs/adr/0012-subagents-not-agent-teams.md`.

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
