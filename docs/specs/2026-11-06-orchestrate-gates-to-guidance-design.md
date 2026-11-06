# Orchestrate: gates become guidance

Date: 2026-11-06
Status: design, pending builder check and operator review
Supersedes in part: `2026-06-18-orchestrate-standing-operator-loop.md` (enforcement
sections), `2026-06-18-orchestrate-claude-code-plugin-design.md` (hook compilation)

## Outcome

Orchestrate stops enforcing its workflow with shell hooks and starts stating it as
directive prose the model follows. Two deterministic pieces survive: a hard stop
against discarding work in the operator's own checkout, and automatic recovery of
the run board after context compaction. The run ledger, metrics, and feedback loop
stay, because they are how we judge whether orchestrate earns its keep. The plugin
gets smaller, friction drops, and it ports to other harnesses with less per-harness
machinery, not more.

## Why now

The hooks encoded two kinds of fact. Facts about git ("never `reset --hard` the
shared checkout") held up: the shared-checkout floor caught real incidents and
almost never misfired. Facts about the workflow ("which branch", "which commands
count as tests", "which paths a persona may write") were brittle: they depended on
the router's own discipline (arming a gate, registering a target, writing a context
record) and on conventions the project may not share.

Evidence, from the boards and run reviews on this machine and one external retro:

- Verifier shell limits: about 290 of 341 refusals in the external retro and 40 of
  58 here were false positives (quoted `>`, python heredocs, scratch writes); two
  reviewers in one day each lost several commands and one fell back to weaker
  static analysis.
- Branch guard: 19 of 21 refusals false positives externally; the one here denied
  a read-only `git branch --show-current`.
- Production gate: never engaged in 18 apply runs; the three manual arming steps
  were skipped in practice. A control nobody arms is a convention wearing a uniform.
- Held-out read deny: inert in every run (no held-out directory configured).
- Leases: zero conflicts ever recorded.
- Shared-checkout floor: caught a builder editing the main checkout twice in one
  day externally; two refusals here, both real.

Harness facts changed too (checked against current Claude Code docs, CLI 2.1.318):
agent `model:` frontmatter is honored; native `isolation: worktree` is documented,
guarded by the harness, and cleans up after itself; session-start hooks still fire
after compaction and still re-inject invoked skills truncated to about 5k tokens.
Several hooks were compensation for bugs that no longer exist.

## Goals

- Every rule a persona must follow is readable in its brief, phrased as what to do,
  never as "the hook will refuse you".
- One hard stop: no command that discards work may run against the primary checkout.
- Board recovery after compaction stays automatic.
- The ledger keeps recording what happened in enough detail to compute shipped,
  verify coverage, friction, model mix, and feedback over time.
- The plugin passes `claude plugin validate --strict` and the repo's `scripts/check.sh`
  with a materially smaller test surface.
- Codex and OpenCode installs still produce the skill and persona definitions.

## Non-goals

- No new enforcement mechanism replaces a removed one. If a rule needs teeth later,
  that is a new decision with its own evidence.
- No change to the persona set (researcher, planner, implementer, verifier, actuator)
  or to the status/verdict vocabulary the router routes on.
- No change to the ledger event vocabulary; old boards remain readable by the new
  `metrics` and `status`.
- No attempt to make hooks fire on other harnesses; those harnesses get the skill and
  agents only.

## Anti-goals

- Keeping a gate "just in case". Every surviving deterministic piece must point at
  evidence it caught something real at low friction.
- Rewriting the router brief into another 1,000-line document. If the prose does not
  fit a model's attention, it is not guidance, it is noise.
- Breaking `/orchestrate:status` or `/orchestrate:feedback` on an existing board.

## Decisions (made)

1. **Two hooks survive.** `guard-shared-checkout.sh` (PreToolUse on Bash, persona
   independent) and `on-compaction.sh` (SessionStart, matcher `compact`). Both keep
   journaling denials and reground output exactly as today.
2. **Nine hooks are deleted** with their tests, their `agents.yaml` entries, and every
   mention in prose: deny-heldout-read, keep-on-branch, gate-prod-apply, run-scope,
   guard-merge-base, guard-done, write-scope, on-writer-dispatch, warn-agent-teams.
3. **Worktree per writer is the model.** The router dispatches each implementer with
   the harness's native `isolation: worktree`. Several writers may run at once, each
   in its own tree. Coupling is resolved at merge and by the verifier's downstream
   breakage check; the planner's grep-backed independence proof becomes advice
   ("prefer disjoint tasks"), not a precondition. Deleted: `worktree.sh`, leases, the
   active-writer record, the lease-related ledger subcommands, and the single-writer
   rule in CONTEXT.md, DESIGN.md, and the personas.
   *Base branch (my call, after the builder check).* Native isolation cuts from the
   repo's default branch (`origin/HEAD`) unless the project sets
   `worktree.baseRef: "head"`, in which case it cuts from the current local HEAD.
   The plugin cannot set that. So the router checks once at intake that the base
   the harness will cut from equals the journaled integration base (`goal.base`):
   `git symbolic-ref refs/remotes/origin/HEAD` by default, or `git rev-parse
   --abbrev-ref HEAD` when the project sets `"head"`. On a mismatch it stops and
   gives the operator the one-line fix (`git remote set-head origin <base>`, or the
   setting) and does not dispatch a writer until it matches. The harness names the
   worktree branch, so `dispatched` no longer carries `branch`; `returned` does,
   from the implementer's report and `git worktree list`. The router removes a
   lane's worktree after it lands (the harness sweep keeps trees with unpushed
   commits). Other harnesses: the router runs `git worktree add -b <name> <path>
   origin/<base>` itself; same check, same prose.
3a. **Worktree-local steps run in parallel; shared-target steps run one at a
   time.** A step is *worktree-local* when everything it reads or changes lives
   inside the lane's own copy of the repo: edits, unit tests, local builds, lint,
   a plan against local mocks. A step is a *shared-target step* when its effect
   lands somewhere outside the worktree that another lane could touch at the
   same moment. The router's test is one question: *if two lanes did this at the
   same time, could they see or clobber each other's results?* If yes, the step
   is serial across all lanes, finished before the next starts, even when the
   code behind it was produced in parallel. Shared targets include a Terraform
   state backend (plan and apply both), a cluster or Helm release, a database
   schema, a package or image registry tag, one deployment environment, a DNS
   zone, a shared staging database or physical device under test, a shared CI
   pipeline, and a remote branch two lanes both push to. The tool's own lock
   (Terraform's state lock, for example) is the backstop; a lock error means
   wait or ask, never force-unlock. This replaces the lease mechanism with the
   rule it was trying to encode. The planner names each task's shared targets
   so the router can see the serialization points; a task that names none and
   is not pure code is treated as touching one.
4. **Production changes are a conversation.** Before dispatching an actuator against
   anything the planner tagged `prod` (untagged still reads as `prod`), the router
   shows the operator the target and the reviewed diff and asks. The ledger records
   the answer as a `decision`. The harness's own permission prompt is the non-model
   stop; the plugin adds none.
5. **The ledger is the logging spine, not a gate.** `ledger.sh` keeps `append`,
   `goal`, `clarify`, `decision`, `done`, `retries`, `metrics`, `feedback`,
   `conformance`, and `reground`. `done` warns on stderr when a non-T0 lane has no
   verdict and still appends; `verify_coverage` is the retrospective signal. `reground`
   drops the lease and active-writer checks and keeps ledger intent plus dirty
   worktree detection (any `worktree-*` or `worktree-agent-*` branch with uncommitted
   work is an open lane to reconcile; it still halts on that).
6. **Model tiers live in the agent files.** `agents.yaml` tiers compile to `model:`
   and `effort:` frontmatter as today; the "pass model on every dispatch or pay
   flagship" rule becomes "override only for a named hard item, and journal it".
   One ceiling stays as prose: a persona never runs a bigger model than the main
   loop; effort may go higher (the verifier's `max`, for instance).
   *The `--models=dynamic|quick|inherit` flag is dropped (my call).* `quick` and
   `inherit` are per-dispatch overrides, which this decision retires; the operator
   who wants cheaper runs edits the tier in `agents.yaml` or says so in the goal.
   `ledger.sh goal` loses its fourth argument; `model_policy` on old `goal` events
   stays readable by status. ADR-0033 joins the supersede list.
   The `dispatched` event keeps optional `model`/`effort`; `metrics model_mix` and
   `unjournaled_work` stay.
7. **Codex and OpenCode stay, thinner.** `install-codex.sh` and `install-opencode.sh`
   install the skill and generate persona definitions. All hook wiring, trust
   seeding, self-verify probes, the OpenCode enforcement plugin, and
   `dispatch-persona.sh` are deleted. `harness-lib` loses its hook emitters.
8. **Docs rewritten in place, one new ADR.** ADR-0040 "Gates become guidance"
   records the cut (git facts stay deterministic, workflow facts become prose) and
   supersedes by name: 0002 (single writer over mutation targets), 0006, 0010, 0011,
   0013 is kept (the surviving floor), 0015 stays as prose, 0016, 0017, 0019 stays
   as prose, 0023, 0026, 0027, 0029, 0031 is amended (boundaries are the syllabus,
   there is no backstop), 0032 is narrowed to the surviving hook, 0033, 0035.
   ADR-0039 is the shipyard record already on `main`; PR #69 (0.8.29, per-persona
   writer records) is closed in favor of this design and lands nothing.
9. **Version 0.9.0.** Breaking for anyone relying on the removed hooks.

## What the builder produces

### Prose (the product)

- `skills/orchestrate/SKILL.md`: a router brief under 300 lines. Keep: trust model,
  the loop (reground, intake, clarify, right-size, drive lanes, verify, land,
  feedback), routing tables, right-sizing tiers, context economy, quarantine, ledger
  vocabulary pointer, judgment memory. Rewrite in directive voice. Remove: every
  "the hook enforces", every "fail-closed", leases, active-writer, held-out hook
  mechanics, the enforcement appendix, the measured-failure war stories that justify
  removed gates. Keep one line per surviving hook saying what it does.
- `references/personas/*.md`: replace each "Your boundaries (fail-closed hooks)"
  section with "How you work" in plain directives. Implementer: commit to the branch
  you were given, never create one, never read a held-out path if one is named, prove
  the commit is the artifact. Verifier: you edit nothing in the repo; rehearse in
  scratch or in a detached copy (`git worktree add --detach` or `git archive`); write
  only your verdict file. Researcher and planner: write only your result path.
  Actuator: one declared mutation, confirmed with the operator when prod, never
  concurrent with another live-target step on the same target, and the verifier
  runs the probe. Keep the craft-skill pointer lines.
- SKILL.md carries one short section, "Shared-target steps", stating decision 3a
  as the one-question test with the example list, and one worked example: an
  infrastructure-as-code repo, where editing is parallel across worktrees but
  every plan and apply against the same state is serial. The router classifies
  each task's steps at intake and names the shared targets in the `intake`
  event's note.
- `references/resume.md`: drop leases, active-writer, the hook list. Keep the
  vocabulary and reground description.
- `DESIGN.md`, `README.md`, `KNOWN-LIMITATIONS.md`, `CONTEXT.md`, `TODO.md`: match.
  Known-limitations rows that described compensations for removed hooks go.
  TODO items about removed hooks close with a pointer to ADR-0040.
- `commands/init.md`, `status.md`, `feedback.md`: remove references to leases, acks,
  gate-blocked, denials from removed hooks. Status keeps the denial line (now only
  the shared-checkout floor can produce one).

### Contract and build

- `references/agents.yaml`: `hooks:` block shrinks to the two survivors; capability
  vocabulary simplifies (`write: results-only|spec-only` collapse to `write: results`
  meaning "has the Write tool, scope is prose"); `conventions:` loses `lease_path`,
  `worktree.*` helper fields, `actuator_cred_scope`; `resume:` loses lease and
  active-writer lines.
- `scripts/harness-lib/*.sh`: keep agent emission for all three harnesses; delete
  hook emission for Codex and OpenCode; Claude Code hooks.json emitter reduces to
  the two groups.
- `scripts/build.sh` regenerates `agents/*.md` and `hooks/hooks.json`.
- `bin/`: keep `ledger.sh` and `adr.sh` shims; delete `worktree.sh`.

### Tests (deleted, not skipped)

Delete every unit and integration test whose subject is a removed hook, lease,
active-writer record, worktree helper, prod gate, done gate, write scope, run scope,
Codex hook trust, or OpenCode hook floor. Keep and adjust: ledger append/goal/
retries/metrics/feedback/conformance, reground (dirty worktree halt), build drift,
plugin validate, integrity, status command, telemetry residue, goal anchor,
compaction handoff, hooks safety (now two hooks), install smoke (agents only),
eval fixture and run.sh, plugin install smoke, invocation. The integration writer
lane test changes to dispatch with native worktree isolation.

### Order of work (suggested)

1. ADR-0040 and the contract (`agents.yaml`) first, so the build and tests have a
   target.
2. Runtime: delete hooks and helpers, trim `ledger.sh`, rebuild.
3. Tests: delete and adjust until `plugins/orchestrate/tests/run.sh` and
   `scripts/check.sh` are green.
4. Prose: SKILL.md, personas, resume.md, commands.
5. Docs: DESIGN, README, KNOWN-LIMITATIONS, CONTEXT, TODO, version bump.
6. Installers and harness-lib.
7. Fresh-eyes review of the whole diff against this document before the PR is
   called ready.

## Constraints

- `scripts/check.sh` must pass locally with `yq` v4, `rumdl`, and `claude` present.
- No em dashes in the files this design rewrites (SKILL.md, personas, resume.md,
  commands, the new ADR) or in any paragraph touched elsewhere. Untouched
  paragraphs in DESIGN.md, TODO.md, and KNOWN-LIMITATIONS.md are not swept in
  this change (my call: keeps the review diff focused).
- The surviving `guard-shared-checkout.sh` must resolve the primary checkout from
  the hook payload's `cwd`, not the hook process's cwd: under native isolation the
  implementer's shell runs inside its worktree with no `cd` in the command text,
  so a legitimate in-worktree `reset --hard` would otherwise be denied.
- `AGENTS.md` at the repo root says official docs are fetched live before touching
  hook, frontmatter, or manifest surfaces; the builder re-checks `hooks.md` and
  `sub-agents.md` for the two surviving hooks and the agent frontmatter fields.
- Old boards (`board.jsonl` written by 0.8.x) must still render in
  `/orchestrate:status` and count in `metrics`.
- Commit author and attribution per repo convention; branch from `origin/main`
  once the shipyard ADR-0039 commit is pushed and PR #69 is closed (both done at
  design approval).

## Left to the builder

- Exact wording of the persona directives, within the shape above.
- Whether `conformance` stays in `ledger.sh` (keep if any surviving test uses it).
- How the verifier's detached-copy rehearsal is phrased (worktree vs archive).
- Whether `warn-agent-teams` becomes a line in SKILL.md ("pass `isolation` on every
  dispatch") or in the compaction hook's injected text. Prefer SKILL.md.
- Which of the three per-harness installer sections of README survive verbatim.

## FAQ

**Does removing the hooks make orchestrate unsafe?** The harness's permission
prompts and native worktree guard remain, plus the one hard stop. What goes is
enforcement of workflow conventions that mostly misfired.

**Can I still see when the model ignored guidance?** Yes. `verify_coverage`,
`model_mix`, `unjournaled_work`, and the run review sidecar are unchanged; a lane
closed without a verdict shows up as a coverage gap, not a refusal.

**What if a project needs a held-out test boundary?** State the path in the dispatch;
the implementer is told not to read it. If that proves insufficient, a project-level
`permissions.deny` `Read(path)` rule in the project's settings does it natively.

**Why keep Codex and OpenCode at all?** The repo's charter is portable skills across
three harnesses, and with hooks gone the per-harness cost is a thin agent emitter.
