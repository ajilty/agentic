# orchestrate (Claude Code plugin)

A standing operator loop you feed goals of any altitude (from "bump the conn
limit" to "deploy app A on cluster B" to "ensure prod restores from backup"). It
decomposes them and drives five personas (researcher, planner, implementer,
verifier, actuator), each with only the tools its role needs. Writers build in
parallel, each in its own git worktree; steps that touch a shared target run one
at a time; every change is verified by a fresh-context reviewer; and every run
is journaled so you can judge afterwards whether the loop earned its keep. It
survives interruption and compaction and remembers its judgment across goals.

## Install

**Claude Code**, from this repo's self-marketplace:

```text
/plugin marketplace add ajilty/agentic
/plugin install orchestrate@ajilty
```

Everything ships in the plugin: the five persona agents, the two hooks
(`hooks/hooks.json` registers them automatically), the skill, the commands, and
the `bin/` shims. Nothing runs at install time; artifacts are pre-built and
committed (see "Generated artifacts" below).

**Codex / OpenCode**:

```text
plugins/orchestrate/scripts/install-codex.sh    --scope user   # or --scope project
plugins/orchestrate/scripts/install-opencode.sh --scope user   # or --scope project
```

The installers put the skill (SKILL.md, references/, runtime/) in the cross-tool
`.agents/skills/` root (`~/.agents/skills/` at user scope,
`<repo>/.agents/skills/` at project scope), where both harnesses discover it
(ADR-0034), and generate the persona definitions from `agents.yaml`: persona
TOMLs for Codex, persona agents for OpenCode. They wire no hooks. OpenCode also
gets the `/orchestrate-{init,status,feedback}` command wrappers and a small
plugin that puts the runtime on `PATH` and reruns reground after compaction.

The planner and verifier inherit the session's model on every harness. The
plugin ships no Codex or OpenCode model ID, so the researcher, implementer, and
actuator inherit too unless you name cheaper models before installing:

```text
export ORCHESTRATE_STANDARD_MODEL=<id>   # implementer, actuator
export ORCHESTRATE_ECONOMY_MODEL=<id>    # researcher
```

Use the harness's own model ID (OpenCode: `provider/model-id`). Pick models no
bigger than the one you run the session on, and rerun the installer after
changing either variable (ADR-0041).

Installers are idempotent; `yq` v4 (mikefarah) is required at install time only.

## Use

```text
/orchestrate:init <goal>     # start a goal of any altitude
/orchestrate:init            # no args: resume open lanes (regrounds first)
/orchestrate:status          # read-only status update from the board
/orchestrate:feedback        # record the run review and a rating row
```

The loop is idempotent and self-detecting: an empty ledger starts fresh, open
lanes resume, and compaction recovers automatically. Reground, intake (clarify
only if no oracle is nameable), right-size, drive lanes, verify, land, feedback.
No config file: repo specifics are discovered, defaulted, or set by env.

If the project keeps held-out tests, name their path in the goal (or export
`HELDOUT_ROOT`); the router tells the implementer not to read it and hands it to
the verifier. For a hard boundary, add a `permissions.deny` `Read(<path>)` rule
in the project's own settings.

Writers run under the harness's native worktree isolation, which cuts from
`origin/HEAD` unless the project sets `worktree.baseRef: "head"`. At intake the
router checks that base against the goal's base branch and, on a mismatch, stops
with the one-line fix (`git remote set-head origin <base>`).

## What ships

- **`commands/{init,status,feedback}.md`**: `/orchestrate:init` (the entry
  point; the router brief is `skills/orchestrate/SKILL.md`), `/orchestrate:status`
  (read-only board view), and `/orchestrate:feedback` (durable run review).
- **`agents/{researcher,planner,implementer,verifier,actuator}.md`**: the five
  persona subagents, each with a tools allowlist, a model and effort tier, and,
  for the implementer, `isolation: worktree`. **Generated** (see below).
- **`hooks/hooks.json`**: two hooks. The shared-checkout floor (PreToolUse on
  Bash) and compaction recovery (SessionStart, matcher `compact`). Command paths
  are `${CLAUDE_PLUGIN_ROOT}`-relative, so they are machine-independent.
  **Generated.**
- **`skills/orchestrate/`**: the harness-neutral source of truth: `SKILL.md`
  (the router brief), `references/` (`agents.yaml`, persona bodies,
  `resume.md`), and `runtime/` (`ledger.sh`, `adr.sh`, and the two hook
  scripts). Sibling craft skills (`research`, `plan`, `build`, `verify`) are
  what each persona reads first.

## Generated artifacts (build step)

`agents/*.md` and `hooks/hooks.json` are **build output**, not hand-authored. They
are generated from `skills/orchestrate/references/agents.yaml` (the single
capability contract, which also carries the hook wire map: `script:` + `watch:`
per hook) by `scripts/build.sh` and committed — a marketplace install runs no
build. All harness mapping logic lives in the repo-level `scripts/harness-lib/`
(ADR-0037), shared by this and the Codex/OpenCode installers. After editing `agents.yaml` or any persona body, regenerate:

```text
scripts/build.sh
```

A drift-guard unit check (`tests/test_build.sh`) fails if the committed artifacts
diverge from a fresh build, so this can't be silently forgotten. `yq` (v4,
mikefarah) is required at build time only; the installed plugin needs just git +
coreutils. The static manifest (`.claude-plugin/plugin.json`) and the repo-root
marketplace catalog are hand-authored, not generated.

> A `CLAUDE.md` placed inside this plugin would be ignored by Claude Code —
> persistent instructions for the loop live in `skills/orchestrate/SKILL.md`.

## Onboarding: new vs existing repos

First run on either is just `/orchestrate:init <goal>`. The difference is how
much context pre-exists:

| | New repo | Existing repo |
|---|---|---|
| `.agents/` | gitignore it | add `.agents/` to `.gitignore` (one line) |
| Oracle | Planner authors spec-derived acceptance checks | discovers existing tests; name any held-out path in the goal |
| Judgment memory | `docs/adr/` starts empty, accumulates | optionally seed `docs/adr/` so the Planner recalls prior decisions instead of re-litigating |
| Ops creds | scope the actuator's credentials to its target when the first ops goal appears | same |
| Worktree base | `origin/HEAD` points at the branch you land on | check `origin/HEAD`, or set `worktree.baseRef: "head"` |
| Discovery | nothing to find | base branch, coverage, shared targets discovered at runtime |

## How state is laid out (two-axis split, ADR-0005)

- **Tracked, human-facing:** `docs/specs/` (designs) and `docs/adr/` (cross-goal
  decisions; the judgment memory). These travel with the repo.
- **Gitignored, machine state:** `.agents/` (the board ledger, the per-ticket
  bus, run reviews and feedback). One `.gitignore` entry. Writer worktrees are
  managed by the harness.

## Safety model (what's guaranteed vs guidance)

- **Guaranteed:** the tools allowlist per persona (compiled into each agent
  definition, so a persona without Edit or web cannot use them); the
  shared-checkout floor (a hook that stops `reset --hard`, `clean -f`,
  `checkout -f`, and similar discarding git commands in the primary checkout,
  for every agent); and the harness's own worktree isolation guard and
  permission prompts.
- **Guidance:** everything else. Which branch a writer commits to, which paths a
  persona writes, what counts as a test run, never reading a held-out path,
  running shared-target steps one at a time, and asking before a production
  change are directives in the router and persona briefs. The ledger shows when
  one was skipped: a lane closed without a verdict is a `verify_coverage` gap.
- **Your deployment:** credential scoping for the actuator and for any
  live-environment oracle. ADR-0040 records why the rest is guidance.

## Tests

```text
tests/run.sh                  # zero-dependency suite: runtime behavior + allowlist + drift + manifest
tests/integration/run.sh      # live tier (real claude CLI + agent sessions); self-skips without auth
```

## Field feedback → improving the plugin (ADR-0028)

Every run journals its own review, durably and version-stamped, in the **target** repo
(gitignored axis): `.agents/runs/orchestrate/eval/feedback.jsonl` — one row per run with
the metrics snapshot (shipped / friction / verify_coverage / `model_mix` /
`plugin_version`) — plus the full qualitative review in `eval/reviews/<UTC-ts>.md`, each
point tied to a specific dispatch with evidence.

To improve the plugin from the field, harvest those files **read-only** from the live
repos on this machine (no command needed — this is a convention, not an artifact):

1. Gather: `ls ~/gits/**/.agents/runs/orchestrate/eval/feedback.jsonl` + the review
   sidecars the notes point at.
2. Correlate each improvement item against `docs/adr/INDEX.md` and `TODO.md`: already
   fixed (name the ADR/version), ticketed, NEW, or a **recurrence** — recurrence of a
   ticketed item promotes it to a fix (precedent: ADR-0026).
3. Watch the standing drift signals: `model_mix` all-flagship (ADR-0024),
   researchers with no judgment-shaped output (ADR-0025), `verify_coverage`
   dropping on code-bearing lanes (ADR-0022), `unjournaled_work` above zero, and
   `denials` rising. Since 0.9.0 only the shared-checkout floor writes `denied`
   rows, so a denial means a persona worked in the primary checkout instead of
   its worktree (ADR-0031, ADR-0032).
4. Propose ranked changes (SKILL prose / hook / tier table / test), each with an ADR call.

## Status

0.9.0 removed the workflow-enforcing hooks, leases, and helpers and restated
their rules as directive prose (ADR-0040, [`DESIGN.md` §18](DESIGN.md)). The
open backlog is in [`TODO.md`](TODO.md).

## Known limitations & filing bugs

Some Claude Code harness behaviors (subagent result notifications, compaction
timing) are outside a plugin's reach; orchestrate works around them by keeping
every result and all control state on disk. Before filing a bug, skim
[KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) to tell a harness behavior from an
orchestrate defect; the issue template's first question is exactly that triage.
