---
name: working-with-slack-mcp
description: "Slack MCP search gotchas: search has NO boolean OR (an alternation ANDs every token including the literal word OR and returns zero), from:<@U…> angle-bracket form (bare IDs return zero), to:me is not a complete mention sweep (union it with a bare <@USER_ID> on:<day> search), slack_search_channels returns public channels only, read tools return no permalinks, slack_read_thread wants message_ts not thread_ts (`initialization_failed: Missing value for parameter message_ts`), include_context=false or blow the 25K cap, the real page cap is 20 not 100, invisible channels omitted silently, is:unread degrades to a keyword match, write tools can vanish while reads work. Use when searching Slack messages, sweeping for @-mentions, building per-user or per-channel sweeps, resolving a channel by name, or when search results look implausibly thin."
---

# Working with the Slack MCP — sharp edges

Search and read mechanics for the Slack MCP tools (`slack_search_*`, `slack_read_*`).

## Search query construction

- **`from:` filters need the angle-bracket mention form: `from:<@U0XXXXXXX>`.** A bare
  `from:U0XXXXXXX` returns zero results — the search index treats `from:` user-filters as
  mention tokens, not raw strings.
- **There is NO boolean `OR`.** An alternation is parsed as an **AND over every token,
  including the literal word `OR`**, so `foo OR bar` matches nothing and returns
  `No results found` — indistinguishable from a genuine no-match, with no error and no warning.
  **Split every alternation into separate single-term searches** and union client-side. This is
  the cheapest way to turn a real finding into a confident zero.
- **`on:YYYY-MM-DD` beats `after:`/`before:`** for day-scoped queries — the window forms are
  exclusive and invite off-by-one errors.
- **`to:me after:<date>` is NOT a complete mention sweep.** It skews to DMs and group DMs and
  under-returns channel @-mentions: three in-window messages that literally contained the
  operator's `<@U0XXXXXXX>` token were absent from all five pages of a `to:me` sweep and
  returned by a bare `<@U0XXXXXXX> on:<day>` search. **Always run both forms per day and union
  them** — the second query is what catches a decision you are cited as backing.
- **Don't stop a `to:me` sweep at three pages** on the assumption it caps there; it paged
  cleanly to five and reported genuine end-of-results. Page until the oldest `ts` crosses the
  window floor.
- **`include_context=false` is mandatory on sweeps.** The default `true` attaches surrounding
  messages and blows past the 25K-token response cap on busy days, and the context is rarely
  useful.

## Pagination reality

- **`slack_search_public_and_private` caps each page at 20 results**, regardless of what the
  docs or the `limit` param suggest. There is no broad call that returns a whole week.
- The efficient sweep is therefore **one search per day, fired in parallel** in a single turn,
  then a parallel second round of `cursor` fetches for any day that returned exactly 20. One or
  two rounds cover realistic volumes.
- **Dedupe the union by `(channel_id, ts)`** — results can overlap at page boundaries.

## Blind spots (silent, no errors)

- **Search silently omits channels the bot can't see.** Known-present text in an invisible
  channel returns zero with no error. If a report seems suspiciously thin, this is the likely
  cause; for known-priority private channels use direct `slack_read_channel` reads, and never
  treat search silence as absence.
- **`is:unread` silently degrades to a full-text keyword match** on the word "unread" — no
  unread endpoint is wrapped (`unread_count_display`, `client.counts`, `conversations.mark` are
  absent). Infer "likely unanswered" from thread content and label it as inference.
- **DMs and group DMs the integration can access DO surface in search.** Include them
  deliberately and flag them, or exclude them explicitly — don't be surprised by them.
- **`slack_search_channels` returns PUBLIC channels only.** Private channels that read fine by
  ID come back as `No results found` by name. A zero-result channel search is **not** evidence
  the channel is absent — resolve known-priority private channels by ID and keep the mapping.
- **Channel names are not unique and stale ID maps disagree.** The same display name can map to
  two different channel IDs across files written at different times. Trust an ID map you
  verified with a live read this run over any older one, and re-verify before citing.

## Threads and enrichment

- Classify messages from fields already present — standalone (`thread_ts` absent or equal to
  `ts` with `reply_count == 0`), thread start (`thread_ts == ts`, `reply_count > 0`), thread
  reply (`thread_ts != ts`).
- **Don't eagerly call `slack_read_thread` to fetch parents** — roughly 10s per call and it
  rarely changes a summary. Record the `thread_ts` pointer; fetch on demand.
- **`slack_read_thread` takes `message_ts` (the parent's ts), not `thread_ts`.** Passing
  `thread_ts` fails with `initialization_failed: Missing value for parameter \`message_ts\``.
- **A no-floor detailed channel read beats a windowed one.** `slack_read_channel` with
  `limit` 10-25 and **no `oldest`** returns in-window top-level posts *and* a
  `Thread: N replies (latest: <ts>)` annotation on older parents, in one call — which is how a
  still-live thread whose parent predates the window gets caught. A windowed read hides it.
- **Read tools return no permalinks; search does.** `slack_read_channel` and
  `slack_read_thread` return only `message_ts`, while `slack_search_public_and_private` returns
  a real permalink per hit. Where a message must carry a citable URL and constructing one is not
  acceptable, **recover it by searching a distinctive verbatim string from the body** with
  `include_bots=true` and `on:<date>` — that reliably returns the one hit with its real
  permalink. Where recovery fails, emit `url: null`; never hand back a constructed link as if it
  were observed.
- **Permalinks are otherwise constructible without extra calls:**
  `https://<workspace>.slack.com/archives/<CHANNEL_ID>/p<TS_WITHOUT_DOT>`, plus
  `?thread_ts=<parent_ts>&cid=<CHANNEL_ID>` for thread replies.

## Write tools may vanish while reads work

`slack_send_message` / `slack_send_message_draft` can return
`permission_error: This tool is not available` in a session where every read/search tool works —
session-scoped permission drift, not a bug to debug. Treat any send step as best-effort: emit
the paste-ready text and link in-band as the fallback, and never let a blocked send stall the
deliverable.

## What this skill does not cover

Workspace-specific facts (user/channel IDs, which private channels are visible) — resolve live
via `slack_search_users` / `slack_search_channels`.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
