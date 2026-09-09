---
name: working-with-slack-mcp
description: "Slack MCP search gotchas: sort_dir=\"asc\" silently truncates and still reports \"End of results - No more pages available.\" (19 results vs 40+ on the same query, so union both directions), search has NO boolean OR (an alternation ANDs every token including the literal word OR and returns zero), the to:me mention recipe is neither complete nor self-limiting (it under-returns channel @-mentions, so union it with a bare <@USER_ID> on:<day> search, and it can hard-stop ~13h short of a day cutoff), channel NAMES are not unique so resolve by channel ID, slack_search_channels returns public channels only, read tools return no permalinks, slack_read_thread wants message_ts not thread_ts (`initialization_failed: Missing value for parameter message_ts`), from:<@U…> angle-bracket form (bare IDs return zero), include_context=false or blow the 25K cap, the real page cap is 20 not 100, invisible channels omitted silently, is:unread degrades to a keyword match, write tools can vanish while reads work. Use when searching Slack messages, sweeping a day or a mention backlog, resolving a channel by name, or when search results look implausibly thin."
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
- **Don't stop a `to:me` sweep early on a guessed page cap, and don't trust the stop when it
  comes.** The ceiling is not fixed: one sweep paged cleanly to five and reported genuine
  end-of-results, while a busier backlog hard-stopped at three (see the page-cap bullet under
  Pagination reality below). A run that stopped at three would have looked complete in both
  cases. **Page until the oldest `ts` actually crosses the window floor**, and where it never
  does, say the window was not covered.
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
- **`sort_dir="asc"` silently truncates and still declares completeness.** The same day-scoped
  query returned **19 messages ascending and 40+ descending**, and the short run ended with the
  very same reassuring `"End of results - No more pages available."` the complete run did. No
  error, no partial-results flag, no count to check it against — the truncated set is
  indistinguishable from an exhaustive one. **Union both sort directions on any day-scoped
  sweep** and dedupe as above; one direction alone is not an inventory.
- **The `to:me after:<cutoff>` mention recipe hard-stops at 3 pages / ~59 results.** On a busy
  backlog that ceiling lands roughly **13 hours short** of a full-day cutoff, so the oldest
  mentions in the requested window are simply absent — and, per the truncation bullet above, the
  run still reports itself finished. The ceiling is not a constant: other sweeps of the same
  shape paged to five and genuinely ended, so treat any stop as suspect until the oldest `ts`
  crosses the window floor. Close the gap with a second same-day query in the opposite
  (ascending) direction and merge.

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

## Channel names are not unique — resolve by ID

**Two distinct channels can carry the same name.** Name-based resolution silently reads whichever
one it matches, with no ambiguity warning, so "read #<name>" can hand back a different channel's
messages than the one that was meant — and every downstream count, quote, and permalink inherits
the mistake. Resolve a name to a **channel ID** once via `slack_search_channels`, check whether
more than one row came back before picking, and pass the **ID** to every subsequent read. Carry
IDs, not names, through any multi-step sweep. Two corollaries: that resolution only covers public
channels (see the blind spot above), so private channels need a mapping you keep; and **a stored
ID map goes stale**, because the same display name can map to different IDs in files written at
different times. Trust a map you verified with a live read this run over any older one, and
re-verify before citing.

## Threads and enrichment

- Classify messages from fields already present — standalone (`thread_ts` absent or equal to
  `ts` with `reply_count == 0`), thread start (`thread_ts == ts`, `reply_count > 0`), thread
  reply (`thread_ts != ts`).
- **Don't eagerly call `slack_read_thread` to fetch parents** — roughly 10s per call and it
  rarely changes a summary. Record the `thread_ts` pointer; fetch on demand.
- **`slack_read_thread` takes `message_ts` (the parent's ts), not `thread_ts`.** Passing
  `thread_ts` fails with ``initialization_failed: Missing value for parameter `message_ts` ``.
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
