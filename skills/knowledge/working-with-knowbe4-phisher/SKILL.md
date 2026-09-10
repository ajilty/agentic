---
name: working-with-knowbe4-phisher
description: "KnowBe4 PhishER MCP (get_phisher_message*): only subject:, status: and id: are real filters — from: and reportedBy: return {\"result\":[]} for values verbatim present in the corpus, silently; rows carry no status field so open-vs-resolved needs the query run twice in both polarities; subject: matches word STEMS not exact tokens; paging and subject-filtering return DISJOINT sets so \"not on any page\" is not \"not in the corpus\"; parallel calls fail with `Transport is already connected` and only the first lands; a reported KnowBe4 simulation is identifiable by the KB4:KMSAT_HEADERS tag. Use when querying the PhishER reported-phish queue, scoping a query by reporter or sender, deciding whether an empty result is a real zero, or separating a reported simulation from a reported live phish."
---

# Working with the KnowBe4 PhishER MCP — sharp edges

Reading the user-reported phish queue via `get_phisher_messages` /
`get_phisher_message` / `get_phisher_message_raw` / `get_phisher_message_eml`. Which
mailboxes and campaigns exist is your environment's fact, not this skill's.

## Only three filters are real, and the other two fail silently

- **`subject:`, `status:` and `id:` are evaluated. `from:` and `reportedBy:` are not.**
  Both return `{"result":[]}` for values that are **verbatim present** on a row you can
  fetch by id — no error, no warning. Any reporter- or sender-scoped question has to be
  answered by paging the corpus and filtering client-side.
- **Prove a filter before trusting its zero.** Pin one row by id, then probe the field in
  both polarities against a deliberately bogus value:

  ```
  id:<known-id> status:zzzbogusstatus     -> []          the field IS evaluated
  id:<known-id> -status:zzzbogusstatus    -> the row     negation IS honoured
  ```

  Both holding is what makes an empty result from that field a real zero. This is the
  only cheap way to tell a true zero from a mis-scoped query here.
- **`subject:` matches word STEMS, not exact tokens** — `subject:update` returns rows
  titled Update, Updates and Updated. Run a stem control before trusting any empty
  `subject:` probe; a filter that returns inflections is working, which is what makes its
  silence meaningful.

## Rows carry no status field — run the query twice

`get_phisher_messages` rows have **no status field at all**, so open-vs-resolved cannot be
read off a row. Establish queue state by running the query in both polarities:
`-status:resolved` for the open set and `status:resolved` for the closed set. An empty
`-status:resolved` is a real zero **only** once the positive form has returned rows.

## Paging and filtering return DISJOINT sets

Twelve pages of 25 with an empty query returned 300 messages; `subject:<term>` then
surfaced **18 messages that appeared on none of those pages**. The paged listing behaves
as a recency window, the API returns **no total**, and the last page still came back full.
So **"not on any page" is never "not in the corpus"** — a corpus-absence claim needs a
filtered probe as well as exhausted paging, and even then should be labelled.

## Serialize every call

Parallel calls to this server fail with
`Error calling tool 'get_phisher_messages': Transport is already connected`. **Only the
first of a concurrent batch lands.** Issue every call to this server one at a time.

## Telling a reported simulation from a reported live phish

A KnowBe4 **simulated** phish that a user reports through the Phish Alert Button carries
the tag **`KB4:KMSAT_HEADERS`** on its PhishER row. That tag is the cheapest way to
separate a reported simulation from a reported live phish without touching the awareness-
training console — which matters, because the two are otherwise indistinguishable in the
queue and inflate any "users are reporting phish" count.

## Sibling servers fail independently

A separate KnowBe4 server (the awareness-training/campaign surface) can be dead with
`CONNECTION_CLOSED` while this one answers normally. A KnowBe4 question that needs
campaign data is then unanswerable even though a KnowBe4 tool is present and responding —
name the server you actually swept, not the vendor.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
