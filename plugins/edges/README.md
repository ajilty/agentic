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
| `working-with-knowbe4-phisher` | KnowBe4 PhishER reported-phish queue |
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

- **In-session**: `/edges:harvest` (ships with this plugin) extracts the
  current session's tool-call learnings and confirms candidates with you, then
  hands off to two forked subagents so your session keeps its context:
  `harvest-author` clones, writes, validates, and opens a draft PR;
  `harvest-review` judges each edge fresh (is it an edge, is it already
  covered, is it the shortest form) before the PR is marked ready.
  `/edges:harvest diet <tool>` runs a compression pass on a skill that has
  grown.
- **Between sessions**: the plugin's hooks keep a **failure journal**. Every
  tool error (and every MCP result flagged `isError`) is appended to
  `~/.local/state/edges/journal.jsonl` (`XDG_STATE_HOME` or `EDGES_JOURNAL`
  override) with pointers to the session, transcript, and call. Capture
  scrubs only emails, URLs, IPv4, UUIDs, digit runs and home paths; rows
  still carry people's names, org names, ticket keys and product names, and
  are never safe to quote verbatim. Identity redaction happens at harvest.
  No model runs, nothing interrupts the session; the only surface is one
  line at session start when unharvested rows exist. `/edges:harvest` reads
  the journal alongside the live session, and rows age out after 30 days to
  match transcript retention. Capture is mechanical; judgment stays with the
  human.
- **By hand**: every skill ends with a report link — wrong, stale, or missing
  edges: [file an edge report](https://github.com/ajilty/agentic/issues/new?template=edge-report.yml),
  or PR against `skills/knowledge/` per CONTRIBUTING.md (the plugin
  directories are symlink views). The best report is the raw observation
  (verbatim error strings, response shapes), redacted of tenant specifics.
