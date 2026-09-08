---
name: working-with-mcp-connectors
description: "MCP connector health, tool-agnostic: a dead-token server can expose ZERO tools instead of failing, never appears in the harness's failed-server list, and reports no error at all — silence is the signature, so probe by tool count and a live read-only call, never by the absence of an error. Also: a credential-manager CLI reporting signed out (`op whoami` → `account is not signed in`) is not evidence the servers are down, in either direction. Use when a connector returns nothing, a sweep comes back implausibly clean, a scheduled or unattended run needs a preflight, you are deciding whether a server is actually up, or you are about to report an absence as a finding."
---

# Working with MCP connectors — health and preflight

Edges that belong to no single tool: how to tell whether a connector is actually working, before
its silence becomes a conclusion. Per-tool auth quirks live in that tool's own
`working-with-<tool>` skill.

## A dead connector can fail as emptiness, not as an error

**A server whose token has expired exposes ZERO tools rather than reporting a connection
failure.** Four things hold at once, which is what makes it easy to miss:

- the server is configured and enabled,
- it does **not** appear in the harness's failed-server list,
- it emits **no error** anywhere in the session,
- it simply contributes no tools, loaded or deferred.

Nothing announces it. The run proceeds, that surface contributes nothing, and the output reads as
"clean" for a system nobody actually queried. This has cost a real window of unread data more
than once, and the damage is time-boxed whenever the data behind it expires (pentest loot,
short-retention logs, ephemeral artifacts).

**Probe by presence, not by absence of error.** A preflight that only watches for failures is
blind to this class:

- **Count the tools.** A configured server contributing zero tools is dark until proven
  otherwise — the count itself is the health signal.
- **Make one live read-only call per credential-backed server** and require a row back. A
  connectivity ping that returns `{"connected": true}` without touching data is weaker than a
  one-record read.
- **Name the surfaces that contributed nothing** in the output. An unswept surface is a declared
  blind spot, not an omission, and a reader cannot tell a clean result from an unasked question
  unless you write it down.
- **A re-auth may not fix every server on the same credential.** Servers sharing one credential
  preset can recover independently — re-probe each after a reconnect rather than assuming the fix
  was global.

## The credential CLI is not the arbiter, in either direction

**`op whoami` returning `account is not signed in` is not evidence that credential-backed MCP
servers are down.** Observed: the CLI reported signed-out while MCP servers depending on that same
credential preset answered live calls normally. A server that authenticated earlier keeps working
after the CLI session lapses — separate sessions over the same secret.

This cuts both ways, which is the actual lesson:

- a signed-out CLI produces a **false alarm**, holding a run that would have succeeded, and
- a signed-in CLI produces **false reassurance**, since a server can still be dark for its own
  reasons per the section above.

**Only a live read-only call against the server settles it.** Treat credential-CLI output as
background context, never as a verdict, and never gate a run on it alone.

## Before reporting an absence

A zero-row answer from a dark connector, from an unsupported filter field, and from a genuine
negative all look identical at the call site. Confirm the query actually ran and name which of the
three you ruled out. A negative is only as strong as the evidence that something was asked.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
