---
name: working-with-knowbe4-phisher-mcp
description: "KnowBe4 PhishER MCP (get_phisher_message*, get_phisher_attachment). Load before the first PhishER call in a session and before any parallel batch; covers serialization, which filters are real, paging versus filtering, status polarity, simulation tagging. Also when asked to triage the reported-phish queue, whether an empty result is a real zero, or to separate a simulation from a live phish."
---

# Working with the KnowBe4 PhishER MCP — sharp edges

Reading the user-reported phish queue. Which mailboxes and campaigns exist is your
environment's fact, not this skill's. Campaign and awareness-training data live on a separate
KnowBe4 server that fails independently of this one.

## Only three filters are real, and the other two fail silently

- **`subject:`, `status:` and `id:` are evaluated. `from:` and `reportedBy:` are not.**
  Both return `{"result":[]}` for values that are **verbatim present** on a row you can
  fetch by id. Any reporter- or sender-scoped question has to be answered by paging the
  corpus and filtering client-side.
- **Prove a filter before trusting its zero.** Pin one row by id, then probe the field in
  both polarities against a deliberately bogus value:

  ```
  id:<known-id> status:zzzbogusstatus     -> []          the field IS evaluated
  id:<known-id> -status:zzzbogusstatus    -> the row     negation IS honoured
  ```
- **`subject:` matches word STEMS, not exact tokens** — `subject:update` returns rows
  titled Update, Updates and Updated. Run a stem control before trusting any empty
  `subject:` probe.

## Rows carry no status field — run the query twice

`get_phisher_messages` rows have **no status field at all**, so open-vs-resolved cannot be
read off a row. Establish queue state by running the query in both polarities:
`-status:resolved` for the open set and `status:resolved` for the closed set. An empty
`-status:resolved` is a real zero **only** once the positive form has returned rows.

## Paging and filtering return DISJOINT sets

The paged listing is a recency window with no total, and the last page still comes back full:
`subject:<term>` surfaced messages that appeared on none of the pages already read. "Not on any
page" is never "not in the corpus"; a corpus-absence claim needs a filtered probe plus exhausted
paging, and is labelled.

## Serialize every call

This server is strictly one-at-a-time: in a parallel batch only the first call lands and the
rest fail with `Error calling tool '<tool>': Transport is already connected`.

## Telling a reported simulation from a reported live phish

A reported KnowBe4 simulation carries the tag `KB4:KMSAT_HEADERS` on its PhishER row. Filter on
it to keep simulations out of any "users are reporting phish" count without opening the
awareness-training console.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
