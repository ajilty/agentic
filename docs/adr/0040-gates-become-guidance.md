# Gates become guidance: git facts stay deterministic, workflow facts become prose

## Context

Orchestrate enforced its workflow with eleven shell hooks. They encoded two
kinds of fact. Facts about git ("never `reset --hard` the shared checkout") held
up. Facts about the workflow ("which branch", "which commands count as tests",
"which paths a persona may write") were brittle: they depended on the router's
own discipline (arming a gate, registering a target, writing a context record)
and on conventions the project may not share.

Evidence from the boards and run reviews on this machine and one external retro:

| Control | Evidence |
| --- | --- |
| Verifier shell limits | About 290 of 341 refusals externally and 40 of 58 here were false positives (quoted `>`, python heredocs, scratch writes) |
| Branch guard | 19 of 21 refusals false positives externally; the one here denied a read-only `git branch --show-current` |
| Production gate | Never engaged in 18 apply runs; the three manual arming steps were skipped in practice |
| Held-out read deny | Inert in every run (no held-out directory configured) |
| Leases | Zero conflicts ever recorded |
| Shared-checkout floor | Caught a builder editing the main checkout twice in one day externally; two refusals here, both real |

Harness facts also changed (checked against current Claude Code docs): agent
`model:` frontmatter is honored, native `isolation: worktree` is documented and
cleans up after itself, and `SessionStart` hooks still fire after compaction.
Several hooks were compensation for bugs that no longer exist.

## Decision

Git facts stay deterministic; workflow facts become directive prose in the
router brief and the persona briefs.

- Two hooks survive: `guard-shared-checkout.sh` (PreToolUse on Bash) and
  `on-compaction.sh` (SessionStart, matcher `compact`).
- Nine are removed with their tests and contract entries: deny-heldout-read,
  keep-on-branch, gate-prod-apply, run-scope, guard-merge-base, guard-done,
  write-scope, on-writer-dispatch, warn-agent-teams.
- Worktree per writer. Each implementer is dispatched with the harness's native
  `isolation: worktree`; several writers may run at once. Coupling is resolved
  at merge and by the verifier's downstream-breakage check. The planner's
  independence proof becomes advice, not a precondition. Leases, the
  active-writer record, and `worktree.sh` are deleted.
- Shared-target steps run one at a time. A step whose effect lands outside the
  lane's own worktree (state backend, cluster, schema, registry tag, one
  environment) is serial across lanes. The tool's own lock is the backstop.
- Production changes are a conversation. Before dispatching an actuator at
  anything tagged `prod` (untagged reads as `prod`), the router shows the
  operator the target and the reviewed diff and asks; the ledger records the
  answer as a `decision`.
- The ledger is the logging spine, not a gate. `ledger.sh done` warns on stderr
  when a non-T0 lane has no verdict and still appends; `verify_coverage` is the
  retrospective signal.
- Model tiers live in the agent files. Override only for a named hard item and
  journal it; a persona never runs a bigger model than the main loop.
- The `--models=dynamic|quick|inherit` flag is dropped; `model_policy` on old
  `goal` events stays readable.

## Consequences

- A smaller plugin with a much smaller test surface, less friction, and less
  per-harness machinery. Codex and OpenCode installs get the skill and agents
  only.
- No new enforcement replaces a removed one. If a rule needs teeth later, that
  is a new decision with its own evidence.
- Breaking for anyone relying on the removed hooks (0.9.0).
- Old `board.jsonl` files stay readable: `lease-conflict`, `gate-blocked`, and
  `model_policy` rows are read, never written.

## Supersedes

0002, 0006, 0010, 0011, 0016, 0017, 0023, 0026, 0027, 0029, 0033, 0035.

## Amends

0031 and 0032 (see their `Amended by ADR-0040` sections).

Status: active
