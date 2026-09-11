---
name: working-with-runlayer
description: "Runlayer MCP governance (AI Watch enforcement, policy denies, audit logs). Load when a tool call is denied by policy or connectors go dark after a policy rollout; covers deny shapes and their fixes, audit-log decoding, enforcement versus monitoring-only posture."
---

# Working with Runlayer — sharp edges (MCP governance layer)

How to diagnose and report Runlayer policy denies without fighting the governance layer.

## The enforcement mechanism

- The block is the **AI Watch `mcp_enforce` hook** (`beforeMCPExecution`). Its decision input is
  the MCP server *source* — proxy URL / stdio command / registration state — not the tool or its
  arguments.
- It fires **after tool schemas load**, so `ToolSearch` succeeding proves nothing about whether
  calls will go through. The only reliable probe is one live read-only call per server.

## Three deny shapes — the canned message flattens them; keep them separate

1. **Generic** "Only Runlayer-managed MCP servers are allowed" — an unmanaged proxy/server.
   Fix class: scope the policy or route the server through Runlayer.
2. **"Not registered in Claude Code settings and cannot be verified"** — seen for
   connector-provisioned servers (e.g. a claude.ai-provisioned M365 connector). Fix class:
   register the server.
3. **403 `policy_with_conditions` with audit-log IDs** — Runlayer's *own* tools, blocked by a
   conditioned policy. Fix class: review the policy's conditions.

Each implies a different fix, so report them per-server, never as "Runlayer/MCP is broken."

## Decoding a deny

- The policy id cited in a deny may be **unfindable in PBAC**. The **Runlayer audit log** is the
  decoder: it names the hook decision and its inputs.
- `query_docs_filesystem_runlayer` is the documentation oracle — use it instead of reading local
  hook files (the deny text forbids touching them, and the docs tool reliably answers posture
  questions).

## Posture knobs (owner decisions, never yours)

- **`Enforcement` MDM flag** vs **Enforce-policy allowlists** are distinct layers; a
  monitoring-only posture exists: `runlayer setup hooks --install --yes --no-enforcement`.
- An outage can have **two independent layers** (connector config and policy hook) — fixing one
  (an `/mcp` reconnect) does not clear the other; re-probe after each layer's fix.

## Discipline when denied

Honor the deny text: **one probe per server, no retries, no workaround attempts, no settings
edits**. Present the fix as a decision for whoever owns the enforcement posture, with the deny
shape and its fix class named. Whether non-MCP CLIs (`gh`, `az`, `aws`) may be used while MCP is
policy-gated is a policy call for that owner — ask, don't assume.

## What this skill does not cover

Changing enforcement posture, editing policies, or installing/modifying hooks — those are
security-configuration actions for the person who owns them.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
