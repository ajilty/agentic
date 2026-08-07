# Decision Index

Rebuilt from docs/adr/*.md by `adr.sh reindex`. The Planner reads this at
intake and does not re-litigate an active decision; a goal contradicting one
raises a DECISION_FORK citing it (supersede flow).

| ADR | Decision | Status |
|-----|----------|--------|
| [0001](0001-extend-orchestrate-not-augment-superpowers.md) | Extend orchestrate rather than augment superpowers | active |
| [0002](0002-single-writer-over-mutation-targets.md) | Single-writer is defined over mutation targets, not files | active |
| [0003](0003-judgment-memory-in-repo-not-harness.md) | Judgment memory is in-repo and tracked, never harness memory | active |
| [0004](0004-router-owns-sequencing.md) | Router owns sequencing; sub-skills are invoked for work, not control flow | active |
| [0005](0005-filesystem-two-axis-split.md) | Filesystem two-axis split — tracked docs/ vs gitignored .agents/ | active |
| [0006](0006-per-dispatch-context-via-on-disk-active-writer.md) | Per-dispatch enforcement context via an on-disk active-writer record | active |
| [0007](0007-plugin-is-generated-distribution-of-agents-yaml.md) | Plugin packaging is a generated distribution of the agents.yaml contract | active |
| [0008](0008-subdir-plugin-monorepo-over-repo-root.md) | Subdir-plugin monorepo over repo-root-as-plugin | active |
| [0009](0009-clarification-returns-pass-quarantine.md) | Clarification-skill returns pass the quarantine gate | active |
| [0010](0010-run-scope-denylist-not-allowlist.md) | Verifier run-scope is a best-effort mutation denylist, not an allowlist | active |
| [0011](0011-writeahead-on-pretooluse-dispatch-not-subagentstart.md) | Writer write-ahead fires on PreToolUse of the dispatch tool, not SubagentStart | active |
| [0012](0012-subagents-not-agent-teams.md) | Orchestrate dispatches capability-subtracted subagents, not agent-teams teammates | active |
| [0013](0013-shared-checkout-destructive-git-floor.md) | A universal floor refuses destructive git on the shared (primary) checkout | active |
| [0014](0014-disk-first-read-lane.md) | Read-only results are disk-first: durable, attributed, gated on read | active |
| [0015](0015-front-door-clarify-gate.md) | Clarification is a front-door gate keyed on a nameable oracle, not a post-Planner fallback | active |
| [0016](0016-codex-hook-enforcement-scope.md) | Codex enforces fail-closed hooks for the MAIN agent's hooked tools, not for spawned subagents or apply_patch | active |
| [0017](0017-codex-confine-personas-via-top-level-exec.md) | Confine Codex personas with a top-level `codex exec --cd`, not in-session `spawn_agent` | active |
| [0018](0018-runtime-helpers-on-path-not-plugin-root.md) | Runtime helpers resolve via plugin `bin/` on PATH, not `${CLAUDE_PLUGIN_ROOT}` | active |
| [0019](0019-writer-proves-its-commit.md) | The writer proves its commit; verification runs against the committed state, not the working tree | active |
| [0020](0020-board-carries-run-level-goal-anchor.md) | The board carries a run-level goal anchor, so a clean board is still resumable | active |
| [0021](0021-delegate-on-context-cost-not-difficulty.md) | Delegate on context cost, not difficulty: a second-strike tripwire for diagnosis | active |
| [0022](0022-oracle-must-be-a-function-probe.md) | A valid oracle is an independent function probe; pair the Verifier by default | active |
| [0023](0023-agent-teams-incompatible-detect-and-warn.md) | Agent teams is incompatible with orchestrate's isolation; detect and warn (no opt-out) | active |
| [0024](0024-horsepower-binds-at-dispatch.md) | Per-persona horsepower binds at dispatch, not at agent registration | active |
| [0025](0025-researcher-is-two-jobs-spec-gaps-not-bought-back.md) | Researcher is two jobs; a T1 spec gap is not bought back by implementer model tier | active |
| [0026](0026-verifier-scratch-carveout.md) | The verifier run-scope floor carves out scratch roots for rehearsals | active |
| [0027](0027-merge-lands-on-journaled-base.md) | Merges on the shared checkout must land on the journaled integration base | active |
| [0028](0028-feedback-lands-durably.md) | Run feedback lands durably: review sidecar, version stamp, dev-side harvest | active |
| [0029](0029-worktree-base-from-journaled-goal.md) | Writer worktrees cut from the journaled goal base, not the operator's current checkout | active |
| [0030](0030-append-stamps-ts-and-flags-noncanonical-events.md) | `ledger.sh append` stamps ts and flags non-canonical events; helpers must out-earn raw echo | active |
| [0031](0031-personas-carry-their-boundaries.md) | Personas carry their boundaries up front; hooks are the backstop, not the syllabus | active |
| [0032](0032-denials-are-journaled-friction.md) | Every enforcement denial is journaled to the board; instrumentation over a verbose mode | active |
| [0033](0033-model-policy-rides-goal-anchor.md) | Dispatch model policy is a run-level operator toggle riding the goal anchor | active |
| [0034](0034-skill-native-installs-via-agents-skills.md) | Codex and OpenCode installs are skill-native via the cross-tool .agents/skills root | active |
| [0035](0035-run-scope-mirrors-verdict-write-allowance.md) | run-scope mirrors the verifier's verdict-write allowance; one contract, every layer | active |
| [0036](0036-plugin-taxonomy-enable-boundary.md) | Plugins are enable boundaries; skills carry the trigger | active |
| [0037](0037-harness-emitters-live-in-repo-level-lib.md) | ADR-0037: Harness emitters live in a repo-level lib; the contract carries the wire map | active |
| [0038](0038-repo-wide-plugin-test-and-validation-convention.md) | 0038: Repo-wide plugin test and validation convention | active |
| [0039](0039-shipyard-product-plugin-structural-pauses.md) | Shipyard ships as a product plugin of user-invoked segments with structural pauses | active |
