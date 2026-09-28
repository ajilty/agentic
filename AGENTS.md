# AGENTS.md

This repo authors portable agent skills and plugins for multiple harnesses (Claude Code, OpenAI Codex, opencode), distributed via the ajilty marketplace. Portable skills live in `skills/`, plugins in `plugins/`.

`CLAUDE.md` is a symlink to this file. Claude Code v2.1.277+ reads `AGENTS.md` natively, but not in every session (Bedrock, telemetry disabled, hooks disabled by policy — its native support ships as the built-in `agents-md` plugin). The symlink covers those sessions, gets this file listed in `/memory` and `/context`, and fires `InstructionsLoaded` hooks; content is never loaded twice. Keep it.

## Before pushing

Run `scripts/check.sh` (the `pre-push` hook runs it too; CI runs the same script). A local failure that also reproduces on main is not pre-existing unless main's latest CI run is red on the same check (`gh run list --branch main --workflow tests`); otherwise it is environment drift, usually a newer `claude` CLI than main was last tested with, and it blocks the PR. See README "Contributing setup".

## Official docs: fetch live, don't trust memory

Harness plugin/skill APIs move faster than any local copy or model training data. Before you write or change a skill, plugin, hook, command, subagent persona, MCP integration, marketplace entry, or eval case, pull the relevant doc below and treat it as the source of truth for any enumerable API surface: hook event names, frontmatter fields, manifest schemas, grader types. Fetching costs one call; a hallucinated field name costs a release.

Every page linked here serves raw markdown when you append `.md` to its URL (all verified fetchable by agents).

### Portable specs: the contract

This repo compiles one source to three harnesses, so the vendor-neutral specs are the contract and the per-harness docs are the deltas. Reach for these to decide what a skill or plugin *is* — directory layout, frontmatter fields, manifest schema — then the harness docs for how that harness loads it.

- **Agent Skills** — [specification.md](https://agentskills.io/specification.md): `SKILL.md` frontmatter fields and their exact constraints, directory layout (`scripts/`, `references/`, `assets/`), progressive-disclosure budgets. Authoring guides live under `skill-creation/`, notably [optimizing-descriptions.md](https://agentskills.io/skill-creation/optimizing-descriptions.md) and [evaluating-skills.md](https://agentskills.io/skill-creation/evaluating-skills.md). Index: [llms.txt](https://agentskills.io/llms.txt).
- **Agent Plugins** — [specification.md](https://agent-plugins.org/specification.md): vendor-neutral packaging of skills and MCP servers into one portable plugin, stewarded by a TSC spanning Amazon, Cursor, Microsoft, OpenAI, and Vercel. [manifest.md](https://agent-plugins.org/plugin-authors/manifest.md) defines `plugin.json` — the schema is closed, so harness-specific keys belong under `extensions`. Canonical JSON schemas: [/schemas](https://agent-plugins.org/schemas). Index: [llms.txt](https://agent-plugins.org/llms.txt).
- **MCP** — [modelcontextprotocol.io](https://modelcontextprotocol.io/): protocol spec, plus [build-server](https://modelcontextprotocol.io/docs/develop/build-server) when authoring one. Index: [llms.txt](https://modelcontextprotocol.io/llms.txt).
- **Skill authoring method** — [Anthropic skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices.md).

### Per-harness docs: the deltas

| Workflow | Claude Code | OpenAI Codex | opencode |
|---|---|---|---|
| Docs index | [llms.txt](https://code.claude.com/docs/llms.txt) | [llms.txt](https://learn.chatgpt.com/docs/llms.txt) | none; append `.md` per page |
| Skills | [skills.md](https://code.claude.com/docs/en/skills.md) | [build-skills.md](https://learn.chatgpt.com/docs/build-skills.md) | [docs/skills](https://opencode.ai/docs/skills) |
| Plugins | [plugins.md](https://code.claude.com/docs/en/plugins.md), [plugins-reference.md](https://code.claude.com/docs/en/plugins-reference.md) | [build-plugins.md](https://learn.chatgpt.com/docs/build-plugins.md), [plugins.md](https://learn.chatgpt.com/docs/plugins.md) | [docs/plugins](https://opencode.ai/docs/plugins) |
| Marketplaces | [plugin-marketplaces.md](https://code.claude.com/docs/en/plugin-marketplaces.md) | see plugins reference | n/a |
| Evals | [plugin-evals.md](https://code.claude.com/docs/en/plugin-evals.md) — `claude plugin eval`, its case/grader format and CI gate; distinct from `claude plugin validate`, which checks files rather than behavior | n/a | n/a |
| Hooks | [hooks-guide.md](https://code.claude.com/docs/en/hooks-guide.md), [hooks.md](https://code.claude.com/docs/en/hooks.md) (reference) | [hooks.md](https://learn.chatgpt.com/docs/hooks.md) | no hooks; plugin event subscriptions ([docs/plugins](https://opencode.ai/docs/plugins)) |
| Commands | folded into skills; see [skills.md](https://code.claude.com/docs/en/skills.md) | deprecated in favor of skills | [docs/commands](https://opencode.ai/docs/commands/) |
| Subagent personas | [sub-agents.md](https://code.claude.com/docs/en/sub-agents.md) | [agents-md.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md.md) | [docs/agents](https://opencode.ai/docs/agents/) |
| MCP (configure) | [mcp.md](https://code.claude.com/docs/en/mcp.md) | [extend/mcp.md](https://learn.chatgpt.com/docs/extend/mcp.md) | [docs/mcp-servers](https://opencode.ai/docs/mcp-servers/) |

`developers.openai.com/codex` permanently redirects to `learn.chatgpt.com/docs`; either works.

## Vendored skills

`.agents/skills/` holds third-party skills with no official-docs equivalent (opinionated method, not harness API), pinned in `skills-lock.json`. Every harness reads them: opencode and Codex via `.agents/skills` directly, Claude Code via `.claude/skills` symlinks. Install or update only with `npx skills add <pkg> -a claude-code codex` (two agent targets force symlink mode; a single target silently copies and breaks the layout).
