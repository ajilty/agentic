---
name: working-with-jira-mcp
description: "Atlassian MCP Jira (searchJiraIssuesUsingJql, getJiraIssue, edit and transition tools). Load before the first Jira call in a session and before composing JQL; covers response-size caps, identity and mention lookups, changelog gaps, concurrency. Also when asked to sweep for @-mentions of a person."
---

# Working with the Jira side of the Atlassian MCP — sharp edges

Read- and write-path failure modes for Jira via the Atlassian MCP (and the `acli` fallback).
Tenant facts (cloudId, projects, custom-field numbers, workflow IDs) are your environment's —
discover them live.

## Transport, token, and response-shape discipline

- **`searchJiraIssuesUsingJql` bloats past the 25K-token cap even with narrow `fields`** — every
  node embeds avatar URLs (4 sizes × user/reporter/assignee), project metadata, and self-links
  regardless. Keep `maxResults` small (50 → 25 → 10), resume via `nextPageToken`. On overflow
  the tool saves the JSON to a temp file and returns the path (three overflows in one session,
  88-185K characters): **reading the spill beats a narrower re-query** — `jq` it
  (`.issues.nodes[] | {key, summary: .fields.summary, status: .fields.status.name}`).
  **Cut `maxResults`, not `fields` — the bloat is per-*node* overhead, not per-field.** Every
  user node (assignee, reporter, comment author) carries four `avatarUrls` plus a `self` URL, so
  a 20-issue page that includes `assignee` costs far more than 20 summaries, and dropping a
  field or two barely moves it. Measured: **~1.5K of avatar and self-URL overhead per issue**,
  enough that a request for four narrow fields still overflows; 20-25 results with a narrow
  field list is safe; a 30-result `text ~ "<term>"` query overflowed *with* an explicit narrow
  field list and spilled to a temp file.
- **`cloudId` accepts the bare site URL** (`<your-site>.atlassian.net`) on `getJiraIssue` and
  the Confluence read tools alike, so `getAccessibleAtlassianResources` is not a required first
  call. That saves a round trip, which matters when the transport is serialized against another
  consumer.
- **Never call `getJiraIssue` without an explicit `fields` list** — the default is `*all` and
  returns everything, including rendered descriptions in multiple formats.
- **Pass `responseContentFormat: "markdown"` when reading comments** — ADF (the default) is a
  JSON tree 3-10x the token weight of the same text.
- **Cap concurrent Atlassian MCP calls at ~3.** An 8-call parallel Jira batch dropped the
  transport for ~15 minutes, unresponsive with no error.
- **`ORDER BY lastmodified ASC` hangs** where the same query with `DESC` returns instantly. Sort
  descending and reverse client-side.
- **The served schema drifts in both directions** (a parameter like `searchResultMode` appears,
  then vanishes with `additionalProperties: false`). Read the served schema at session start.
  When a count mode exists it **returns full issue payloads anyway** — compute counts
  client-side; never trust `count` to be cheap.
- Never request `description`/`comment` in the *search* step — only in per-issue `getJiraIssue`.

## JQL limits (the traps that look like bugs)

- **JQL has no `commentBy` / `changedBy` / "field-edited-by" operator.** "Issues where X
  authored a change in window W" cannot be expressed. Over-fetch a candidate set, then filter
  client-side against each issue's changelog and comments. Canonical candidate query:
  ```jql
  ( worklogAuthor = "{ACCT}"
    OR assignee was "{ACCT}" DURING ("{START}", "{END_EXCLUSIVE}")
    OR (assignee = "{ACCT}" AND updated >= "{START}" AND updated < "{END_EXCLUSIVE}")
    OR (reporter = "{ACCT}" AND created >= "{START}" AND created < "{END_EXCLUSIVE}") )
  AND updated >= "{START}" AND updated < "{END_EXCLUSIVE}" ORDER BY updated DESC
  ```
- **`assignee = X AND updated >= ...` matches ghost activity** — the issue updated, but by
  someone else. Always follow with a changelog walk filtering `author.accountId == X`; drop
  issues with zero surviving events.
- **Issue creation is NOT in `changelog.histories[]`.** The creator lives on
  `fields.creator` (+ `fields.created`); synthesize the create event from those. This is the
  single biggest correctness gap in activity summaries.
- **JQL has no `mention` field.** "Issues where someone @-mentioned X" cannot be expressed;
  `text ~ "Display Name"` is the only available proxy and it matches the display-name **literal
  anywhere** in summary, description or comments. So it returns issues whose mention is months
  stale, and misses any mention rendered without that literal. **Every hit needs its comment
  thread read** to tell an in-window ask from old text — treat the query as a candidate
  generator, never as an answer.
- **`comment ~ "text"` matches OLD comments on freshly-updated issues** — an `updated` window
  does not window the comment matches. Content aimed at a person may also live in *description
  edits*, which no comment JQL sees; only a changelog read catches those.
- **Dates:** quoted strings, evaluated in the **site timezone**. Use half-open ranges
  (`>= start AND < end_exclusive`); `<= end` silently means `end 23:59:59.999`. Prefer absolute
  dates over `now()`/`startOfDay()` for reproducibility.
- Quote accountIds (they contain `:`, a reserved character). Prefer `in (...)` over ≥3 `OR`
  disjuncts. Sprint names aren't unique — use sprint IDs (readable off a member issue's sprint
  custom field).

## Identity resolution (accountIds)

- **`lookupJiraAccountId` can return zero for a real user** (email masked on privacy-restricted
  accounts). Fall back to the display-name form (`first.last` → `First Last`) and require an
  exact case-insensitive `displayName` match; with zero or multiple exact matches, surface
  candidates and stop — never guess. The people-search ranks by recency, not exactness.
- **One human can hold multiple accountIds** (one per email domain on federated/post-merger
  tenants, or legacy duplicates with identical displayName — one with email, one without). Jira
  never merges them, and events land on whichever authored them. Resolve a handle by probing the
  literal input, `local@<domain>` for each known tenant domain, and the displayName — union the
  results, run the activity pipeline for **every** accountId, and merge timelines. Don't prefer
  the email-having duplicate; the active account is often the email-less one.
- **`currentUser()` resolves to exactly ONE of them, silently**, so `assignee = currentUser()`
  returns a clean, plausible, partial answer. Write every accountId into the clause:
  `assignee IN ("<id1>", "<id2>")`.
- **Deactivated accounts drop out of user search, not out of data.** Resolve via a known issue's
  assignee/reporter field, or email-literal JQL (`assignee = 'user@domain'`) — both still work.

## Write path

- **Tenants can enforce the issue-type hierarchy** (e.g. Initiative > Epic > Story/Task >
  Sub-task): `createJiraIssue` and `editJiraIssue parent` reject skip-level parenting. Resolve
  the full parent chain to a valid **adjacent-level** parent before any create.
- **`createJiraIssue` accepts `transition: {id}` at creation** — land the new issue directly in
  the target status in one call instead of create-then-transition.
- **Transition IDs are workflow-bound.** When a project binds every issue to one shared
  workflow, the IDs are uniform — verify once with `getTransitionsForJiraIssue`, then batch
  without per-issue lookups; re-verify on the first rejection.
- **Permission classifiers can non-deterministically deny one call in an identical batch** —
  surface the denial and retry after an explicit user go-ahead; don't silently hammer-retry.

## `acli` fallback (when the MCP transport is down)

`acli` is the reliable JQL fallback, with its own limits: `--fields` rejects some field names
(e.g. `parent`, `updated`, `duedate`), `--filter` and `--jql` are mutually exclusive, and its
parser rejects `status changed ... DURING (...)` clauses — use bounded `updated >=/<` ranges.

## What this skill does not cover

Tenant-specific facts (cloudIds, board filters, custom-field numbers, transition IDs) — discover
and verify them live.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
