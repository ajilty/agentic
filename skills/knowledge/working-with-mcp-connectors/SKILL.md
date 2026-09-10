---
name: working-with-mcp-connectors
description: "MCP connector health and answer-shape, tool-agnostic: the dominant failure is not an error but a confident, well-formed, INCOMPLETE answer — ask the question a second way and compare counts before reporting anything as complete or absent. A dead-token server can expose ZERO tools instead of failing, never appears in the failed-server list, and reports no error. A vendor server responding does not mean the vendor data is reachable; a sibling server can be down. Strict serialization shows up as \"Transport is already connected\" with only the first concurrent call landing. A filter parameter may be evaluated or silently ignored — pin a known row and probe both polarities against a bogus value. A credential CLI reporting signed out is not evidence the servers are down, in either direction. Use when a connector returns nothing, a sweep comes back implausibly clean, a count looks too round, a run needs a preflight, or you are about to report an absence or coverage claim as a finding."
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

## Other servers on the same credential, and the same vendor, fail independently

**A vendor's tools being present and responding does not mean the vendor's data is reachable.**
Observed in one session: two servers fronting the same vendor, one answering normally and the
other dead with `CONNECTION_CLOSED`. A question needing the dead half was unanswerable while a
tool bearing that vendor's name sat right there, responding. Name the *server*, not the vendor,
when you record what you swept.

## Strict serialization looks like a transport bug

Some servers accept exactly one call at a time. Fired as a parallel batch, **only the first
lands** and the rest fail — the tell is a transport-level message rather than a query error,
e.g. `Error calling tool '<name>': Transport is already connected`. It is not something to
debug or retry harder: serialize every call to that server for the rest of the session. Treat a
transport-shaped error inside a parallel batch as a concurrency limit until proven otherwise.

## The dominant failure is not an error — it is a confident, incomplete answer

Across one day of heavy multi-connector work, **nine of eleven distinct tool failures produced
no error at all**: a well-formed, plausible, *incomplete* result. Silent scope limits (an
unsupported boolean, a case-sensitive enum, a filter field the endpoint doesn't have, a
repository or folder the search cannot see) and wrong-shaped answers (an envelope value where
the caller assumed the real one, a capability flag where the caller assumed reachability) both
land as clean output. Nothing in the response distinguishes them from the truth.

**The generic defence is to ask the question a second way and compare the counts.** Not a
re-run — a *different* query with a different mechanism, whose answer should agree:

- a filtered count against an unfiltered count, or a facet sum against the reported total;
- a search-index answer against a non-search-index answer (a direct listing, a graph/API call,
  a notification feed);
- an aggregate against a distinct count (a limited `groupBy` looks complete; a `distinct`
  returns the truth);
- one identity or scope form against another (a mention token against a "to me" filter, a
  display name against an id).

**Disagreement is the finding.** Where the two agree, the number is reportable; where they
don't, the gap is what you write down. Where you only ever asked once, say the coverage is
unverified.

## Is that filter real? Pin a known row and probe both polarities

An unsupported filter field usually returns empty rather than erroring, so an empty result
cannot tell you whether the filter worked. **Pin one record you know matches, then test the
filter against a deliberately bogus value in both directions:**

```
<known-id-filter> <field>:zzzbogusvalue    -> [] means the field IS evaluated
<known-id-filter> -<field>:zzzbogusvalue   -> the row means negation IS honoured
```

If both hold, an empty result from that field is a real zero. If the bogus value returns the
row anyway, the field is being ignored and every conclusion built on it is void. The same
two-sided probe distinguishes "no matches" from "query mis-scoped" in one cheap pair of calls.

Two related traps worth checking before trusting a filtered corpus:

- **Paging and filtering can return disjoint sets.** Twelve pages of 25 with an empty query
  returned 300 records, and a *filtered* query then surfaced 18 more that appeared on none of
  those pages. Where the API returns no total and the last page still comes back full,
  **"not on any page" is never "not in the corpus."**
- **Text filters may match word stems, not exact tokens.** A filter for one word returning that
  word's plural and past tense is the control that proves the tokenizer is working — which is
  what makes a genuinely empty result trustworthy rather than an artifact.

## Before reporting an absence

A zero-row answer from a dark connector, from an unsupported filter field, and from a genuine
negative all look identical at the call site. Confirm the query actually ran and name which of
the three you ruled out. Where the tool exposes a scanned-work counter (events processed, chats
scanned vs listed, records examined), **read it** — zero rows over zero work scanned is not a
negative, it is an unasked question. A negative is only as strong as the evidence that
something was asked.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
