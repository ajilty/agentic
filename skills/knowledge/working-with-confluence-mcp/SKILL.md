---
name: working-with-confluence-mcp
description: "Atlassian MCP Confluence gotchas, read and write: CQL contributor queries return folders-only without type in (page, blogpost, comment), \"did anyone answer this\" needs THREE comment calls per page (inline/open, inline/resolved, footer) because getConfluencePageInlineComments defaults to resolutionStatus open and footer comments are invisible to both, CQL lastmodified is day-granular only, a bad space key in space in (...) returns a silent zero, serial-only transport, 25K-token spill files, title vs body escaping asymmetry, numeric spaceId requirement, ADF-legal HTML. Use when calling createConfluencePage / updateConfluencePage / getConfluencePage, checking whether a comment or question was ever answered, or querying activity via CQL."
---

# Working with the Confluence side of the Atlassian MCP — sharp edges

Read-path (CQL search) and write-path (`createConfluencePage` / `updateConfluencePage` /
`getConfluencePage`) mechanics. Which space or parent page to use is your environment's fact,
not this skill's.

## Transport discipline

- **Treat the Atlassian transport as serial-only for Confluence.** Observed on at least one
  tenant: a 4-call parallel batch dropped the transport for ~15 minutes with no error, while the
  Jira side of the same server tolerated ~3 concurrent.
- **The 25K-token response cap spills to a temp file** on large reads: a single
  `getConfluencePage` on a big page, or `getConfluenceSpaces type=personal limit=100`. For an
  existence check use a metadata path or accept the CQL hit; when you genuinely need a spilled
  body, `grep` the temp file rather than reading it whole. Filter space listings by owner up
  front.

## CQL / activity queries (read path)

- **`type in (page, blogpost, comment)` is required on `contributor =` queries.** Without it,
  CQL returns *only folders* — the #1 silent failure mode. One `type in (...)` query covers
  pages and comments together; don't issue per-type queries. The folders-only failure is
  specific to `contributor =`: `mention =` and `watcher =` queries returned real pages without
  the clause on one tenant, so don't assume every CQL user-predicate needs it.
- **A bad space key inside `space in ("A","B","C")` returns a silent zero for that key**, not an
  error, so a "nothing in space X" claim built on a multi-key query is untrustworthy on its own.
  Validate each key with a bare `space = "<KEY>"` probe before reporting an absence.
- **`lastmodified >= "YYYY-MM-DD"` is day-granular only** — CQL cannot express an intra-day
  window start. Over-fetch the whole day and filter client-side on the returned timestamp,
  which is itself a **relative string**, so the boundary filter is approximate: a hit half an
  hour outside a mid-morning window start will survive it. Say so rather than presenting the
  window as exact.
- **Comments are already in the unified result:** `type: "comment"` rows carry the body excerpt
  in `summary`, a title of `"Re: <parent page title>"`, and a `webUrl` with
  `?focusedCommentId=`. Don't call `getConfluencePageFooterComments` /
  `getConfluencePageInlineComments` per page for *enumeration* — only when threads, full bodies,
  or answered/unanswered state are needed. When they are, see below: it takes three calls.
- **Create vs edit, cheaply:** the CQL result doesn't say which. If `author.displayName` matches
  the target user and `lastModified` is in-window, mark `created`; else `edited`. Version-level
  detail needs a per-page `getConfluencePage` — do that only on explicit request.
- **One human may hold multiple accountIds** (multi-domain or post-merger tenants), and a user
  lookup can return a plausible-but-inactive sibling account. On zero results for a
  believed-active user, treat it as a resolution failure first: probe the lookup once per known
  email domain, then re-query with `contributor in (<id1>, <id2>)`.
- **Deactivated accounts drop out of user search but remain queryable** by email literal in CQL —
  absence from people-search is not absence from history.
- `lastModified` returns as a **relative string** ("yesterday at 2:05 PM") — preserve it and
  note the ambiguity rather than fabricating an ISO timestamp.
- Paginate via `cursor`; past a few hundred results, summarize and ask for a narrower range.

## "Did anyone answer this?" needs THREE calls per page

The comment tools each cover a disjoint slice, and each one's silence looks like an answer.

- **`getConfluencePageInlineComments` defaults to `resolutionStatus: "open"`** and silently
  omits the rest. Measured on one page: the default call returned 2 of a user's 4 comments;
  passing `resolutionStatus: "resolved"` returned a 3rd.
- **The 4th was a FOOTER comment, invisible to both inline calls** — and it was the only
  genuinely unanswered one, and the most substantive. Only `getConfluencePageFooterComments`
  returned it.
- So the complete sweep is **inline/open + inline/resolved + footer**. Stopping after the inline
  calls reports a page's one real open question as answered.
- **`getConfluencePageFooterComments` with `includeReplies: true` returns an explicit
  `hasReplies` boolean per comment** — a clean deterministic "nobody answered" signal. Use it
  rather than inferring from an empty replies array or scraping the page.

## Create / update mechanics (write path)

- **`title` is plain text — do NOT entity-escape it.** Passing `Auth &amp; Access` stores and
  displays the literal `&amp;`. The **body is the opposite**: under `contentFormat: "html"` the
  body IS HTML and ampersands there must be `&amp;`.
- **`cloudId` accepts the site URL** (`<your-site>.atlassian.net`) directly — no need to resolve
  the UUID first.
- **`createConfluencePage` requires a numeric `spaceId`** even when `parentId` is given. Resolve
  a space key → id with `getConfluenceSpaces keys:"<KEY>"`; never guess the number.
- **Read an existing page before matching it.** `getConfluencePage` with `contentFormat: "html"`
  returns clean, round-trippable HTML — pull a prior page to copy its exact structure, style,
  and lozenge colors rather than guessing.

## Storage format / rendering

- **`html` is a supported `contentFormat` and is round-trip-safe.** When an HTML body is
  rejected, it is an *invalid-HTML* rejection, not "HTML unsupported": the body must follow ADF
  nesting rules (no block elements inside inline elements, no headings inside table cells). Read
  the descriptive error and fix the nesting — don't fall back to markdown/ADF.
- **Prefer HTML over markdown for tables or nested bullets.** Markdown won't synthesize an ADF
  table from headings and flattens nested `<ul>` inside table cells; HTML round-trips them
  intact. Hand-building ADF is higher-risk than HTML for the same result.
- **Markdown auto-linkifies dot-tokens** — a bare `session.id` becomes a URL on publish. Write
  it in a code span or author via HTML.
- **Status lozenge:**
  `<span data-type="status" data-color="green|blue|purple|red|yellow|neutral">Label</span>` —
  copy the label vocabulary and colors from the tenant's existing pages.
- **Full-width tables:** `<table data-layout="full-width">`; a plain `<table>` defaults to the
  narrow layout.
- Nested sub-bullets (`<ul><li>…<ul>…</ul></li></ul>`) render fine. Never wrap body content in
  `<html>`/`<head>`/`<body>`.

## Publishing discipline

A page publish is externally visible. Assemble the exact page, show the user the exact text, and
publish only on explicit approval of that text. For a high-stakes edit to a shared page, leave
the final write to the user.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
