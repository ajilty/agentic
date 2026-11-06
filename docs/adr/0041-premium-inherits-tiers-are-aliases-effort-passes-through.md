# Premium personas inherit the main loop; tiers are aliases; effort passes through

## Context

ADR-0024 made the router carry every persona's model and effort on every
dispatch because Claude Code ignored agent `model:` frontmatter. ADR-0040 then
recorded that frontmatter is honored, moved the tiers back into the agent
files, and set the ceiling: a persona never runs a bigger model than the main
loop. The compiled tiers did not match that ceiling, and the Codex and OpenCode
tiers had gone stale.

Live tests on this machine, 2026-11-06 (probe scripts are not tracked):

| Harness | Setup | Result |
|---|---|---|
| Claude Code 2.1.318 | opus main loop, researcher (`model: haiku`), no model on the call | ran haiku |
| Claude Code 2.1.318 | sonnet main loop, researcher (`model: haiku`), no model on the call | ran haiku |
| Claude Code 2.1.318 | haiku main loop, verifier (`model: opus`), no model on the call | ran **opus** |
| Codex 0.166.0, ChatGPT account | default model and `gpt-5.6-sol`, `model_reasoning_effort = "max"` | accepted, ran |
| Codex 0.166.0, ChatGPT account | `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` (the compiled tiers) | rejected: not supported with a ChatGPT account |

So frontmatter binds, and it binds upward: an agent file that names opus runs
opus under a haiku main loop. A fixed ladder with opus at the top breaks the
ceiling whenever the main loop runs below opus, and does nothing when it runs
above. The Codex `max` to `xhigh` clamp rested on a claim no official source
makes, and every Codex model ID the plugin compiled was unusable on this
account.

Official sources, fetched the same day:

- Claude Code [sub-agents](https://code.claude.com/docs/en/sub-agents.md):
  `inherit` means "use the same model as the main conversation"; resolution
  order is the per-invocation `model` parameter, then the definition's `model`
  frontmatter, then `CLAUDE_CODE_SUBAGENT_MODEL`, then the main conversation's
  model, so an omitted `model:` ends at the main loop. "On an Agent tool call,
  that parameter takes a model alias: `sonnet`, `opus`, `haiku`, or `fable`.
  Claude can't pass a full model ID or `inherit` on that call." Effort is one
  of `low`, `medium`, `high`, `xhigh`, `max`, and "available levels depend on
  the model".
- OpenCode: `model` is a concrete `provider/model-id` with no alias or
  `inherit` keyword; omitting it inherits the invoking session's model.
  `{env:...}` substitution applies to its JSON config files only; agent
  markdown frontmatter is parsed as plain YAML (`ConfigMarkdown.parse` in
  `anomalyco/opencode` v1.19.5), so the installer must resolve any model ID
  itself.
- Codex: a spawned agent with no `model` inherits the parent's model and
  effort; a role that sets `model` alone keeps a previously resolved effort
  unvalidated, so model and effort are emitted together.
- Effort guidance ([model-config](https://code.claude.com/docs/en/model-config),
  [optimizing for cost and intelligence](https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence),
  the Academy tutorials on effort and model choice): start at the model's
  default, step one level at a time, and do not leave effort on `max`, which
  "may show diminishing returns and is prone to overthinking". Missing checks
  call for more effort; a wrong approach calls for a bigger model. On one
  coding benchmark Opus 5.5 at `medium` solved 92.8% at $0.21 per solved task
  and at `xhigh` 96.7% at $0.74 (Anthropic-internal, directional).

## Decision

- **Premium is the main loop's model.** Planner and verifier carry no model on
  any harness and inherit it. The ceiling holds by construction, and nothing
  has to judge what sits above opus.
- **Standard and economy are the harness's cheaper aliases, clamped at the
  main loop.** Claude Code compiles `sonnet` and `haiku`. Because frontmatter
  binds upward, the router clamps at dispatch: when the main loop is at or
  below a persona's alias, it passes the main loop's own alias on the call,
  the highest-precedence lever the plugin has. An unrecognized main-loop family
  counts as above every alias.
- **Codex and OpenCode ship no model ID.** Their installers emit a model for
  standard and economy personas only when `ORCHESTRATE_STANDARD_MODEL` or
  `ORCHESTRATE_ECONOMY_MODEL` is set at install time, and never for premium.
  Unset means inherit. This replaces the `ORCHESTRATE_OC_MODEL_*` variables and
  the Anthropic default ladder ADR-0037 introduced for OpenCode.
- **Effort passes through unchanged** on every harness; the harness or model
  clamps an unsupported level. The Codex `max` to `xhigh` clamp is removed,
  and Codex roles always carry effort.
- **Defaults and one sanctioned escalation.** Researcher `medium`, planner
  `high`, implementer `medium`, verifier `high`, actuator `high`. `max` is not a
  default anywhere. After a `REJECTED` verdict that reads as missed checks, the
  implementer is re-dispatched at `high` on the same model; a rejection that
  reads as the wrong approach moves the model up one rung within the ceiling
  instead. Every escalation is journaled on `dispatched`.

## Considered options

- **Keep the fixed ladder (opus premium).** Rejected: it breaks the ceiling
  under any main loop below opus, measured above.
- **Derive the ladder from a live model catalog.** Rejected: the claims it
  needed (newest-first listing, alias drift detection) were refuted, and it
  adds a network dependency for a capability no harness honors.
- **Keep premium as an alias and clamp it at dispatch like the others.**
  Rejected: omitting the model gets the same result without depending on the
  router remembering, and is the only portable spelling of "same as the main
  loop" on all three harnesses.
- **A watcher subagent that retunes effort mid-run.** Rejected: a running
  subagent's effort cannot change on any harness, and every adjustment point is
  an event the router already owns.

## Consequences

- ADR-0024's per-dispatch pass survives as the clamp and override lever, not a
  mandate to restate the agent file on every call. Its consequence that
  "nothing relies on" frontmatter no longer holds: the agent files are the
  default.
- Planner and verifier cost now moves with the main loop: cheaper under a
  sonnet main loop, dearer under a model above opus.
- On this machine Codex inherits everywhere until the operator names an ID the
  account accepts. Changing either variable needs a reinstall.
- The cost-heat accent gives planner and verifier the same color, since they
  now share a tier and effort.
- Whether `effort:` frontmatter binds for plugin agents is documented but not
  re-tested; effort is not self-reportable.
- Breaking for OpenCode installs that set `ORCHESTRATE_OC_MODEL_*`.

## Amends

0024 (see its `Amended by ADR-0041` section) and 0037's Consequences bullet
"OpenCode emits tier models (Anthropic ladder default, `ORCHESTRATE_OC_MODEL_*`
overrides)" (see its `Amended by ADR-0041` section).

Status: active
