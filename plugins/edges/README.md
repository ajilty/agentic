# edges

Auto-invoked knowledge skills: `working-with-<tool>` notes that fill model gaps
on the sharp edges of specific tools and vendors. Generic by rule: zero user or
company references; this is the publishable tier.

Skills are symlinked views into the repo-root
[`skills/knowledge/`](../../skills/README.md) library; edit and search there,
not here.

## Skills

| Skill | Surface |
|---|---|
| `working-with-aws-cli` | `aws` CLI (SSO, SSM RunCommand, CloudTrail) |
| `working-with-confluence-mcp` | Atlassian MCP, Confluence read + write |
| `working-with-crowdstrike-mcp` | falcon-mcp (NG-SIEM CQL, FQL tools) |
| `working-with-entra-graph` | `az rest` against Microsoft Graph / Entra ID |
| `working-with-github-cli` | `gh` across a SAML-protected enterprise |
| `working-with-horizon3-mcp` | Horizon3 / NodeZero pentest results |
| `working-with-jira-mcp` | Atlassian MCP, Jira reads + writes, JQL |
| `working-with-m365-connector` | Microsoft 365 / Outlook connector |
| `working-with-mcp-connectors` | MCP connector health and preflight (tool-agnostic) |
| `working-with-playwright` | Playwright headless capture in uv venvs |
| `working-with-runlayer` | Runlayer MCP governance denies |
| `working-with-slack-mcp` | Slack MCP search and reads |
| `working-with-splunk-mcp` | Splunk MCP (session expiry, index picking, result shapes) |
| `working-with-wiz-mcp` | Wiz MCP cloud/K8s hunting |

## Improving these skills

Authoring rules (edge shape, size, redaction, validation, PR flow) live in
[CONTRIBUTING.md](CONTRIBUTING.md) — the single source both lanes follow:

- **In-session**: the user-invoked `/harvest` skill (also `/edges:harvest`) (ships with this plugin)
  harvests the current session's tool-call learnings, confirms candidates, and
  submits the PR itself.
- **By hand**: every skill ends with a report link — wrong, stale, or missing
  edges: [file an edge report](https://github.com/ajilty/agentic/issues/new?template=edge-report.yml),
  or PR against `skills/knowledge/` per CONTRIBUTING.md (the plugin
  directories are symlink views). The best report is the raw observation
  (verbatim error strings, response shapes), redacted of tenant specifics.
