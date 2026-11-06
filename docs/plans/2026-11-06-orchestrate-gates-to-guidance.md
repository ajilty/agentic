# Orchestrate 0.9.0: Gates to Guidance Implementation Plan

> **For agentic workers:** one fresh builder per task, in order; each task ends with the plugin test suite green and a commit. A fresh reviewer reads the whole branch against the spec before the PR is called ready. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove orchestrate's workflow-enforcing hooks, leases, and helpers; keep the shared-checkout git floor, compaction recovery, and the ledger; restate every removed rule as directive prose.

**Architecture:** The plugin keeps its shape (skill + personas + generated agents + hooks.json + runtime scripts + commands) but the `hooks:` block in `agents.yaml` shrinks to two entries, `ledger.sh` loses leases and the active-writer record, and SKILL.md becomes a short router brief. Codex and OpenCode installers emit agents and the skill only. Each task leaves `plugins/orchestrate/tests/run.sh` green.

**Tech Stack:** bash, `yq` v4 (mikefarah), `claude plugin validate --strict`, `rumdl`; Claude Code plugin format (hooks.json, agents/*.md frontmatter).

**Spec:** `docs/specs/2026-11-06-orchestrate-gates-to-guidance-design.md`

## Global Constraints

- Branch `orchestrate/gates-to-guidance` from `origin/main` (local main was pushed at design approval; PR #69 is closed).
- `scripts/check.sh` must pass before push; the pre-push hook runs it.
- Fetch `https://code.claude.com/docs/en/hooks.md` and `sub-agents.md` before editing hooks.json emission or agent frontmatter (AGENTS.md rule).
- No em dashes in files this plan rewrites (SKILL.md, personas, resume.md, commands, ADR-0040, hook script comments touched) or in any paragraph touched elsewhere.
- Old `board.jsonl` files from 0.8.x must still work with `ledger.sh metrics`, `reground`, and `/orchestrate:status` (vocabulary unchanged; `model_policy`, `lease-conflict`, `gate-blocked` rows are read, never written).
- Persona names, status enums (`DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`, `DECISION_FORK`) and verdicts (`APPROVED`, `REJECTED`, `INCONSISTENT_ORACLE`) are unchanged.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; PR body ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Version `0.9.0` in `plugins/orchestrate/.claude-plugin/plugin.json`.

## Review Focus

1. A 0.8.x board containing `lease-conflict` / `gate-blocked` / `model_policy` rows: `ledger.sh metrics` and `reground` must not warn or fail (Task 2 test).
2. `guard-shared-checkout.sh` invoked with a payload whose `cwd` is a linked worktree and a command with no `cd`: must ALLOW `git reset --hard` (Task 2 test).
3. `guard-shared-checkout.sh` with payload `cwd` = primary checkout and `git checkout -b x && git commit -m m`: must ALLOW (no destructive verb; regression from 2026-07-06) (Task 2 test).
4. `ledger.sh done <ticket>` on a T1 lane with no verdict: appends the event AND prints a warning to stderr; exit 0 (Task 2 test).
5. `cc_hooks_json` with an empty watch class must emit valid JSON with no empty group; `claude plugin validate --strict` passes (Task 1 test).

---

### Task 1: Contract, ADR-0040, and the two-hook build

**Files:**

- Create: `docs/adr/0040-gates-become-guidance.md`
- Modify: `docs/adr/INDEX.md` (via `adr.sh reindex` + `supersede`)
- Modify: `plugins/orchestrate/skills/orchestrate/references/agents.yaml`
- Modify: `scripts/harness-lib/claude-code.sh` (`cc_hooks_json`, `cc_agent_md`)
- Modify: `plugins/orchestrate/scripts/build.sh`
- Regenerate: `plugins/orchestrate/agents/*.md`, `plugins/orchestrate/hooks/hooks.json`
- Modify: `plugins/orchestrate/tests/test_build.sh`

**Interfaces:**

- Produces: `agents.yaml` with `hooks:` = `{ shared_checkout_guard: {script: guard-shared-checkout.sh, watch: [shell]}, compaction_reground: {script: on-compaction.sh, watch: [post-compaction]} }`; persona `capabilities.write` values `none | results | full`; implementer persona gains `isolation: worktree`; `conventions:` keeps `state_root`, `ledger`, `artifact_dir`, `heldout_root_env`, `metrics_from_ledger`, `adr_dir`, `adr_index`, `clarification_skills`; removes `lease_path`, `worktree`, `actuator_cred_scope`. `resume:` removes `derived_not_held`'s mention of leases and `ground_truth` stays `git-worktrees`.
- Produces: `hooks/hooks.json` with exactly two groups: `PreToolUse` matcher `Bash` → guard-shared-checkout.sh; `SessionStart` matcher `compact` → on-compaction.sh.
- Produces: `agents/implementer.md` frontmatter line `isolation: worktree`.
- [ ] **Step 1: Branch.** `git fetch origin && git switch -c orchestrate/gates-to-guidance origin/main`.
- [ ] **Step 2: Write ADR-0040** at `docs/adr/0040-gates-become-guidance.md`: title "Gates become guidance: git facts stay deterministic, workflow facts become prose"; sections Context (evidence table from the spec's "Why now"), Decision (two hooks survive; list of nine removed; worktree per writer; shared-target rule; prod ack conversation; ledger as logging spine; model tiers in frontmatter; `--models` flag dropped), Consequences, and a Supersedes list naming 0002, 0006, 0010, 0011, 0016, 0017, 0023, 0026, 0027, 0029, 0033, 0035; Amends 0031 and 0032. Status line `_Status: active_`.
- [ ] **Step 3: Flip superseded ADRs.** From repo root run `plugins/orchestrate/bin/adr.sh supersede NNNN 0040` for each of the twelve, then `plugins/orchestrate/bin/adr.sh reindex`. Append one line to 0031 and 0032 under a `## Amended by ADR-0040` heading saying what changed (0031: boundaries are the whole syllabus, hooks are no longer a backstop; 0032: only the shared-checkout floor journals denials).
- [ ] **Step 4: Edit `agents.yaml`** per Interfaces. Rewrite the header comment to drop the hook vocabulary ("all but none need a write-scope hook" etc.). Keep `tiers:`, `routing:`, `trust:` unchanged.
- [ ] **Step 5: Edit `cc_hooks_json`** in `scripts/harness-lib/claude-code.sh` so a watch class with no hooks emits no group, groups are joined with commas correctly, and `shell` alone maps to matcher `Bash` (not `Read|Bash`). Remove the `Task|Agent` group. Edit `cc_agent_md` to emit `isolation: worktree` when `yq ".personas.$p.isolation"` is non-null. Edit `cc_tools` for the new `write: results` value (Write only).
- [ ] **Step 6: Edit `build.sh`** to drop the `'startup|resume:warn-agent-teams.sh'` extra pair.
- [ ] **Step 7: Run `plugins/orchestrate/scripts/build.sh`** and inspect `hooks/hooks.json` (two groups) and `agents/implementer.md` (`isolation: worktree`, `tools: Read,Grep,Glob,Write,Edit,Bash`).
- [ ] **Step 8: Update `tests/test_build.sh`:** keep allowlist, tier, color, drift, manifest, contract-parity, clarification-binding blocks; add `assert_eq "$(grep -c '"matcher"' "$SK/hooks/hooks.json")" 2 "hooks.json has exactly two hook groups"`; add a check that `agents/implementer.md` contains `^isolation: worktree`; drop the §2a′ tier-table block (replaced in Task 3 by a simpler one).
- [ ] **Step 9: Validate:** `claude plugin validate --strict plugins/orchestrate` passes; `bash plugins/orchestrate/tests/run.sh` shows failures only in tests this plan deletes in Task 2 (list them in the commit message).
- [ ] **Step 10: Commit** `feat(orchestrate): ADR-0040 and two-hook contract`.

### Task 2: Runtime: delete the gates, trim the ledger, fix the surviving floor

**Files:**

- Delete: `skills/orchestrate/runtime/hooks/{deny-heldout-read,keep-on-branch,gate-prod-apply,run-scope,guard-merge-base,guard-done,write-scope,on-writer-dispatch,warn-agent-teams}.sh`, `skills/orchestrate/runtime/worktree.sh`, `skills/orchestrate/runtime/dispatch-persona.sh`, `bin/worktree.sh`
- Modify: `skills/orchestrate/runtime/ledger.sh`, `skills/orchestrate/runtime/hooks/guard-shared-checkout.sh`, `skills/orchestrate/runtime/hooks/on-compaction.sh`
- Delete tests: `tests/test_{lease,prod_gate,read_scope,reground_leases,worktree,writeahead_actuator,writer_ctx,guard_done}.sh`
- Modify tests: `tests/test_{hooks_safety,done_gate,compaction_handoff,metrics_feedback,metrics_delegation,append_contract,runtime_resolution,telemetry_residue,status_command}.sh`
- Create test: `tests/test_legacy_board.sh`

**Interfaces:**

- Produces `ledger.sh` subcommands: `append`, `retries`, `metrics`, `feedback`, `conformance`, `reground`, `decision`, `clarify`, `goal <note> [spec] [base]`, `done <ticket>`. Removed: `lease-key`, `lease-acquire`, `lease-release`, `lease-check`, `ack`, `writer-ctx`.
- `reground` exit codes: 0 clean, 3 when any `worktree-*` or `worktree-agent-*` branch's worktree has uncommitted non-telemetry changes. Blocks (c) leases and (d) active-writer are removed.
- `done`: appends `{"ts","ticket","event":"done"}` always; when the ticket's `intake` tier is not T0 and no `verdict` event exists, prints `orchestrate: warning: <ticket> closed without a Verifier verdict (tier=<t>); verify_coverage will show the gap` to stderr; exit 0.
- `append` canonical set: `goal intake clarify dispatched returned verdict fork decision denied lane done feedback`.
- `guard-shared-checkout.sh`: resolves the git dir with `git -C "$cwd"` where `cwd` is `.cwd` from the stdin JSON, falling back to `$PWD`.
- [ ] **Step 1: Delete** the nine hooks, `worktree.sh`, `dispatch-persona.sh`, `bin/worktree.sh` with `git rm`.
- [ ] **Step 2: Write failing tests** in `tests/test_hooks_safety.sh` (rewrite the file; only two hooks remain): (a) `cwd` = linked worktree, command `git reset --hard origin/main` → exit 0; (b) `cwd` = primary, same command → exit 2 and empty stdout; (c) `cwd` = primary, `git checkout -b x && git commit -m m` → exit 0; (d) no stdin, no env → exit 0; (e) `on-compaction.sh` emits JSON with `hookSpecificOutput.hookEventName == "SessionStart"` when `jq` is present. Feed stdin as `{"tool_input":{"command":"..."},"cwd":"..."}`.
- [ ] **Step 3: Write failing test** `tests/test_legacy_board.sh`: build a board with `goal` (with `model_policy`), `intake`, `dispatched`, `lease-conflict`, `gate-blocked`, `verdict`, `done` rows; assert `ledger.sh metrics` exits 0 and prints `shipped=1`, and `ledger.sh reground` exits 0 and prints `GOAL:` with `[models: quick]`.
- [ ] **Step 4: Rewrite `tests/test_done_gate.sh`:** T1 lane without verdict → exit 0, board gains a `done` row, stderr contains `warning`; T1 with verdict → no warning; T0 without verdict → no warning.
- [ ] **Step 5: Run** `bash tests/run.sh`; expect the new tests to FAIL.
- [ ] **Step 6: Edit `ledger.sh`** per Interfaces. Remove the subcommand cases and the usage line entries; remove reground blocks (c) and (d); keep (a), (b), the GOAL line (still reading `model_policy` for old boards), and the exit-3 HALT on dirty writer work; `goal` drops the fourth positional and the `model_policy` emission; `done` becomes warn-and-append.
- [ ] **Step 7: Edit `guard-shared-checkout.sh`:** parse `cwd="$(J .cwd)"; [ -n "$cwd" ] || cwd="$PWD"`; use `git -C "$cwd" rev-parse --git-dir` and `--git-common-dir`; replace em dashes in comments with colons; trim the header comment to five lines.
- [ ] **Step 8: Edit `on-compaction.sh`** text: drop "retry budgets are counted from disk" mention of leases if present; keep the re-invoke-the-skill instruction.
- [ ] **Step 9: Adjust** `test_compaction_handoff.sh` (remove writer-ctx steps), `test_metrics_feedback.sh` and `test_metrics_delegation.sh` (remove lease/ack/gate setup; keep `denials`, `verify_coverage`, `model_mix`, `unjournaled_work` assertions), `test_append_contract.sh` (canonical set), `test_runtime_resolution.sh` and `test_telemetry_residue.sh` (no `worktree.sh`; create worktrees with plain `git worktree add`), `test_status_command.sh` (no leases).
- [ ] **Step 10: Run** `bash tests/run.sh`; expect `FAIL=0`.
- [ ] **Step 11: Commit** `refactor(orchestrate): remove gate hooks, leases, worktree helper; ledger warns instead of refusing`.

### Task 3: Prose: router brief, personas, resume, commands

**Files:**

- Rewrite: `skills/orchestrate/SKILL.md` (target under 300 lines)
- Rewrite sections: `skills/orchestrate/references/personas/{researcher,planner,implementer,verifier,actuator}.md`
- Rewrite: `skills/orchestrate/references/resume.md`
- Modify: `commands/{init,status,feedback}.md`
- Regenerate: `agents/*.md` (`scripts/build.sh`)
- Modify: `tests/test_build.sh` (tier table parity), `tests/test_integrity.sh` (unchanged logic; must pass)

**Interfaces:**

- SKILL.md sections, in order: frontmatter (description unchanged in intent; drop "single-writer" and "fail-closed"; keep the USE FOR / DO NOT USE FOR lists; `compatibility:` says runtime needs git and coreutils, `HELDOUT_ROOT` optional); "What this is"; "Trust model" (§0 table, unchanged); "The loop" (reground → intake and goal → clarify if no oracle nameable → right-size → drive lanes → verify → land → feedback); "Dispatching" (pass `isolation: worktree` on every writer dispatch; read-only personas write their result to the path you mint and end with `<!-- orchestrate:complete -->`; read results from disk; one line on the craft-skill pointer); "Shared-target steps" (spec decision 3a verbatim test + example list + the IaC worked example); "Production changes" (ask the operator with target + diff; record a `decision` event); "Right-sizing" (T0/T1/T2 table unchanged; the tier table reduced to `persona | model | effort` rows matching agents.yaml); "Context economy" (keep the delegate-on-reduction-ratio heuristic and the second-strike tripwire, four paragraphs max); "Routing" (status and verdict tables, BLOCKED backing table, DECISION_FORK payload); "Quarantine" (§4 and §4a condensed to one section); "Worktrees and landing" (intake base check from spec decision 3; land via PR when the repo convention is PRs, else merge onto the integration base after `git rev-parse --abbrev-ref HEAD` equals it; remove the lane's worktree after landing); "Ledger" (pointer to resume.md, canonical events, `done` warns); "Judgment memory" (§11 condensed); "Hooks" (two lines: what the shared-checkout floor refuses; what compaction recovery injects).
- Persona briefs: replace "Your boundaries (fail-closed hooks ...)" with "How you work"; implementer: commit to the branch your worktree is on, never create or switch branches, never read a path named as held-out, prove the commit (ADR-0019 text kept); verifier: edit nothing in the repo, rehearse in scratch or a detached copy (`git worktree add --detach <tmp> <commit>` or `git archive`), write only the verdict file; researcher and planner: write only the result path you were given; actuator: one declared mutation, never concurrent with another step on the same shared target, operator confirmation when the target is prod, verifier runs the probe. Remove every "refused", "hook", "lease", "ack", "gate-blocked", "lease-conflict". Planner's `parallel_groups` block becomes "prefer disjoint tasks; name each task's shared targets" with the YAML reduced to `shared_targets: [<kind>:<scope>, ...]` and `consequence: prod | safe` per task.
- `resume.md`: vocabulary block without `lease-conflict`, `gate-blocked`, `branch` on `dispatched` (moves to `returned`), `model_policy`; "Hooks, in total" lists the two.
- `commands/init.md`: drop the `--models` flag section; `commands/status.md`: drop leases/acks/`model_policy` lines, keep denials, unjournaled_work, runtime-freshness, compaction nudge, feedback-gap footers; `commands/feedback.md`: unchanged except em dashes.
- [ ] **Step 1: Write the tier-table parity test** in `tests/test_build.sh`: for each persona, a SKILL.md row `| <persona> | <model> | <effort> |` must match `cc_tier_model(agents.yaml tier)` and effort. Run; expect FAIL (old table format).
- [ ] **Step 2: Rewrite SKILL.md** per Interfaces. Check `wc -l` < 300 and `grep -c ', '` = 0.
- [ ] **Step 3: Rewrite the five persona sections** per Interfaces; `grep -lE 'hook|lease|ack|refused' references/personas/` returns nothing.
- [ ] **Step 4: Rewrite resume.md** and the three commands per Interfaces.
- [ ] **Step 5: Run `scripts/build.sh`**, then `bash tests/run.sh` → `FAIL=0`; `rumdl check plugins/orchestrate` clean on the rewritten files.
- [ ] **Step 6: Commit** `docs(orchestrate): router brief and personas as directive prose`.

### Task 4: Plugin docs and version

**Files:**

- Modify: `plugins/orchestrate/{DESIGN.md,README.md,KNOWN-LIMITATIONS.md,CONTEXT.md,TODO.md}`, `plugins/orchestrate/.claude-plugin/plugin.json`
- [ ] **Step 1: `plugin.json`:** version `0.9.0`; description: "Standing operator loop: feed goals of any altitude; capability-scoped personas work in parallel worktrees, shared-target steps run one at a time, verification is independent, and every run is journaled for retrospectives."
- [ ] **Step 2: DESIGN.md:** rewrite §2 goals (drop "Fail-closed" and "subtraction is structural"), §3 (worktree per writer), §6 (capability model: tools allowlist only), §8 (held-out as prose), §9 (durability without leases), §10 (hook philosophy: the git-fact vs workflow-fact test, two hooks), §12 file map, §15 limitations, add §18 "0.9.0: gates become guidance" pointing at ADR-0040.
- [ ] **Step 3: README.md:** "What ships" and "Safety model" sections rewritten (guaranteed: tools allowlist, shared-checkout floor, harness worktree guard; everything else guidance); Install/Use keep the commands; drop `--models`; keep "Field feedback" section.
- [ ] **Step 4: KNOWN-LIMITATIONS.md:** delete rows and sections that describe compensations by removed hooks (worktree-isolation section, agent-teams section becomes one paragraph "pass isolation on dispatch", model-frontmatter section becomes "fixed upstream; per-call override still wins", Codex table reduced to the `max` effort row and the sandbox row); keep the notification-channel table and the compaction section.
- [ ] **Step 5: CONTEXT.md:** remove Lease, Blast radius, Consequence level, Pre-apply gate entries; add "Shared-target step" and "Worktree-local step" with the spec's definitions; update Relationships.
- [ ] **Step 6: TODO.md:** close items about removed hooks with "resolved by ADR-0040 (removed)"; keep live items (command parity, naming of helper subagents, eval A/B).
- [ ] **Step 7: `bash tests/run.sh`** → `FAIL=0`; `claude plugin validate --strict plugins/orchestrate` passes.
- [ ] **Step 8: Commit** `docs(orchestrate): 0.9.0 design, readme, limitations, context`.

### Task 5: Installers and harness library

**Files:**

- Modify: `scripts/harness-lib/codex.sh` (delete `codex_derive_wiring`, `codex_write_hooks_json`, `codex_print_pretooluse_toml`, `ensure_hooks_feature`, `ensure_network_access`, `strip_seed_block`, `hook_trust_oracle`, `write_seed_block`, `selfverify_trust`, `codex_seed_hook_trust`; keep `codex_sandbox`, `codex_model`, `codex_effort`, TOML emission)
- Modify: `scripts/harness-lib/opencode.sh` (`oc_plugin_ts` keeps only the `shell.env` PATH injection and `session.compacted` → on-compaction.sh; delete `oc_calls` and the `tool.execute.before` floor)
- Modify: `scripts/harness-lib/common.sh` (`install_skill` no longer chmods a hooks dir that may be empty; `hooks_watching*` stay)
- Modify: `plugins/orchestrate/scripts/install-codex.sh`, `install-opencode.sh` (addenda: PATH line, "dispatch personas natively", no launcher, no hooks, no trust; summaries without hook/lease/cred text)
- Modify: `plugins/orchestrate/tests/test_install.sh`
- Delete: `tests/integration/test_{codex_apply_patch_route,codex_persona_confine,codex_safety_lane,codex_trust_seed,opencode_hook_floor,safety_gate,safety_shared_checkout,safety_writescope,writeahead_dispatch,handoff_lane}.sh`
- Modify: `tests/integration/test_{conformance_lane,writer_lane,invocation,codex_schema,opencode_install}.sh`

**Interfaces:**

- Codex install produces: `$SKILLS_ROOT/orchestrate/{SKILL.md,references/,runtime/}` and `$DEST/agents/<persona>.toml` only.
- OpenCode install produces: skill, `$DEST/agents/*.md`, `$DEST/commands/orchestrate-{init,status,feedback}.md`, `$DEST/plugins/orchestrate.ts` (PATH + compaction only).
- [ ] **Step 1: Update `test_install.sh`:** remove hooks.json, trust, network_access, dispatch-persona, `--models` assertions; add `assert_no_file "$o/hooks.json"` for codex and `! grep -q 'tool.execute.before' "$o/plugins/orchestrate.ts"` for opencode. Run; expect FAIL.
- [ ] **Step 2: Edit the two lib files and two installers** per Files/Interfaces.
- [ ] **Step 3: Delete the listed integration tests; edit the rest:** `test_writer_lane.sh` dispatches the implementer with `isolation: worktree` and asserts the commit landed on a `worktree-*` branch and the primary checkout is untouched; `test_conformance_lane.sh` and `test_invocation.sh` drop writer-ctx / gate steps; `test_codex_schema.sh` and `test_opencode_install.sh` drop hook assertions.
- [ ] **Step 4: Run** `bash tests/run.sh` → `FAIL=0`; `bash tests/integration/run.sh` → `FAIL=0` (skips allowed).
- [ ] **Step 5: Commit** `refactor(orchestrate): codex and opencode installs emit agents and skill only`.

### Task 6: Whole-branch check, review, PR

- [ ] **Step 1: `scripts/check.sh`** from the repo root → all sections pass.
- [ ] **Step 2: Grep the plugin** for stale vocabulary: `grep -rnE 'lease|writer-ctx|gate-blocked|run-scope|write-scope|keep-on-branch|deny-heldout|dispatch-persona|worktree\.sh|--models' plugins/orchestrate --include='*.md' --include='*.sh' --include='*.yaml' --include='*.json'` returns only ADR history references or nothing. Fix stragglers.
- [ ] **Step 3: Fresh-eyes review:** give the reviewer the diff `origin/main...HEAD` and the spec path, not conclusions; read-only; findings ranked with a failure scenario each; checks the PR description against the code. Fix or answer every finding.
- [ ] **Step 4: Push and open the PR** titled `orchestrate 0.9.0: gates become guidance`, body: outcome, the two surviving hooks, what was removed, the shared-target rule, how old boards are handled, link to spec and ADR-0040, attribution line.

### Task 7: Evergreen model and effort tiers (added after the model-tier hand-off)

Source: the hand-off at the session scratchpad `handoffs/model-and-effort-selection.md` (live-tested on Claude Code 2.1.318 and Codex 0.166.0). Runs after Task 5; before Task 6.

**Files:**

- Modify: `plugins/orchestrate/skills/orchestrate/references/agents.yaml` (`tier:` values and header comment)
- Modify: `scripts/harness-lib/claude-code.sh` (`cc_model`, `cc_color`), `scripts/harness-lib/codex.sh` (`codex_model`, `codex_effort`), `scripts/harness-lib/opencode.sh` (`oc_model`)
- Modify: `plugins/orchestrate/skills/orchestrate/SKILL.md` (tier table and the paragraph under it), `plugins/orchestrate/KNOWN-LIMITATIONS.md` (Codex `max` row; model-frontmatter section), `plugins/orchestrate/README.md` (Codex/OpenCode env variables)
- Modify: `plugins/orchestrate/tests/test_build.sh` (WANT_MODEL, WANT_EFFORT, WANT_COLOR, tier-table parity), `plugins/orchestrate/tests/test_install.sh` (OpenCode model defaults), `plugins/orchestrate/tests/integration/test_model_tier_lane.sh`
- Create: `docs/adr/0041-premium-inherits-tiers-are-aliases-effort-passes-through.md`; amend `docs/adr/0024` with a pointer.
- Regenerate: `plugins/orchestrate/agents/*.md`

**Interfaces:**

- `agents.yaml` tiers: researcher `{model: economy, effort: medium}`, planner `{model: premium, effort: high}`, implementer `{model: standard, effort: medium}`, verifier `{model: premium, effort: high}`, actuator `{model: standard, effort: high}`. Header comment: premium = the main loop's model (inherit); standard and economy = the harness's cheaper aliases, clamped at the main loop; effort passes through unchanged.
- Claude Code: `cc_model premium` emits nothing (no `model:` line, which inherits); `standard` → `sonnet`, `economy` → `haiku`. `cc_color` keeps the heat ladder with premium hottest.
- Codex: `codex_model` emits `model = "<id>"` only when `ORCHESTRATE_STANDARD_MODEL` / `ORCHESTRATE_ECONOMY_MODEL` is set for that tier, never for premium; `codex_effort` passes every level through unchanged (no `max → xhigh` clamp); effort is always emitted.
- OpenCode: `oc_model` emits `model: {env:ORCHESTRATE_STANDARD_MODEL}` / `{env:ORCHESTRATE_ECONOMY_MODEL}` only when that variable is set at install time, never for premium; no Anthropic default IDs remain in the lib.
- SKILL.md tier table rows become `| <persona> | <tier word: inherit, sonnet, haiku> | <effort> |`; the paragraph under it states: a persona never runs a bigger model than the main loop; when the main loop is at or below a persona's alias, pass no model and let it inherit; override a single dispatch upward only within the ceiling for a named hard item and journal it; after a `REJECTED` verdict that reads as missed checks, re-dispatch the implementer at `high`; a rejection that reads as wrong approach moves the model up one rung within the ceiling instead. `max` is not a default anywhere.
- test_build.sh: planner and verifier agent files have no `model:` line; implementer `sonnet`/`medium`; actuator `sonnet`/`high`; researcher `haiku`/`medium`; verifier `high`.
- [ ] **Step 1: Update the test expectations** in `test_build.sh`, `test_install.sh`, and `test_model_tier_lane.sh` per Interfaces. Run `bash plugins/orchestrate/tests/run.sh`; expect FAIL on the tier assertions.
- [ ] **Step 2: Write ADR-0041** (status active; supersedes the per-dispatch mandate reading of 0024; records the live evidence: frontmatter binds both ways on 2.1.318; Codex accepts `max`; the compiled Codex IDs are rejected on a ChatGPT account).
- [ ] **Step 3: Edit agents.yaml, the three harness libs, SKILL.md, KNOWN-LIMITATIONS.md, README.md** per Interfaces. Run `plugins/orchestrate/scripts/build.sh`.
- [ ] **Step 4: Run** `bash plugins/orchestrate/tests/run.sh` → `FAIL=0`; `bash scripts/validate-plugins.sh` passes; `rumdl check` clean on touched files.
- [ ] **Step 5: Commit** `feat(orchestrate): premium personas inherit the main loop; tiers are aliases; effort passes through (ADR-0041)`.
