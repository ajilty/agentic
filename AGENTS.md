# AGENTS.md

This repo authors portable agent skills and plugins for multiple harnesses (Claude Code, OpenAI Codex, opencode), distributed via the ajilty marketplace. Portable skills live in `skills/`, plugins in `plugins/`.

## Before pushing

Run `scripts/check.sh` (the `pre-push` hook runs it too; CI runs the same script). A local failure that also reproduces on main is not pre-existing unless main's latest CI run is red on the same check (`gh run list --branch main --workflow tests`); otherwise it is environment drift, usually a newer `claude` CLI than main was last tested with, and it blocks the PR. See README "Contributing setup".

## Official docs: fetch live, don't trust memory

Harness plugin/skill APIs move faster than any local copy or model training data. For the dev workflows of this repo (creating skills, plugins, hooks, commands, subagent personas, MCP integrations), pull the official docs on the fly and treat them as the source of truth for any enumerable API surface: hook event names, frontmatter fields, manifest schemas.

Entrypoints (all verified fetchable by agents; all three doc sites serve raw markdown when you append `.md` to a page URL):

| Workflow | Claude Code | OpenAI Codex | opencode |
|---|---|---|---|
| Docs index | [llms.txt](https://code.claude.com/docs/llms.txt) | [llms.txt](https://learn.chatgpt.com/docs/llms.txt) | none; append `.md` per page |
| Skills | [skills.md](https://code.claude.com/docs/en/skills.md) | [build-skills.md](https://learn.chatgpt.com/docs/build-skills.md) | [docs/skills](https://opencode.ai/docs/skills) |
| Plugins | [plugins.md](https://code.claude.com/docs/en/plugins.md), [plugins-reference.md](https://code.claude.com/docs/en/plugins-reference.md) | [build-plugins.md](https://learn.chatgpt.com/docs/build-plugins.md), [plugins.md](https://learn.chatgpt.com/docs/plugins.md) | [docs/plugins](https://opencode.ai/docs/plugins) |
| Marketplaces | [plugin-marketplaces.md](https://code.claude.com/docs/en/plugin-marketplaces.md) | see plugins reference | n/a |
| Hooks | [hooks-guide.md](https://code.claude.com/docs/en/hooks-guide.md), [hooks.md](https://code.claude.com/docs/en/hooks.md) (reference) | [hooks.md](https://learn.chatgpt.com/docs/hooks.md) | no hooks; plugin event subscriptions ([docs/plugins](https://opencode.ai/docs/plugins)) |
| Commands | folded into skills; see [skills.md](https://code.claude.com/docs/en/skills.md) | deprecated in favor of skills | [docs/commands](https://opencode.ai/docs/commands/) |
| Subagent personas | [sub-agents.md](https://code.claude.com/docs/en/sub-agents.md) | [agents-md.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md.md) | [docs/agents](https://opencode.ai/docs/agents/) |
| MCP (configure) | [mcp.md](https://code.claude.com/docs/en/mcp.md) | [extend/mcp.md](https://learn.chatgpt.com/docs/extend/mcp.md) | [docs/mcp-servers](https://opencode.ai/docs/mcp-servers/) |

Cross-harness references:

- Skill authoring method (official): [Anthropic skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices.md)
- Building MCP servers: [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/develop/build-server) (index at [llms.txt](https://modelcontextprotocol.io/llms.txt))
- `developers.openai.com/codex` permanently redirects to `learn.chatgpt.com/docs`; either works.

## Vendored skills

`.agents/skills/` holds third-party skills with no official-docs equivalent (opinionated method, not harness API), pinned in `skills-lock.json`. Every harness reads them: opencode and Codex via `.agents/skills` directly, Claude Code via `.claude/skills` symlinks. Install or update only with `npx skills add <pkg> -a claude-code codex` (two agent targets force symlink mode; a single target silently copies and breaks the layout).
