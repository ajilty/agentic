---
name: working-with-horizon3-mcp
description: "Horizon3 / NodeZero MCP (pentest results, weaknesses, weakness series, proofs, schedules, GraphQL). Load before the first Horizon3 call in a session and before writing a GraphQL query; covers auth, filters, paging, introspection, terminology. Also when no horizon3 tool appears at all or when asked about the Remediation Hub."
---

# Working with the Horizon3 / NodeZero MCP — sharp edges

How to drive the Horizon3 MCP for reading autonomous-pentest results. The server is an HTTP MCP
at `mcp.horizon3ai.com`. If tools are deferred, load schemas first (e.g. ToolSearch
`select:mcp__horizon3__run_h3_graphql_query`). **`run_h3_graphql_request` is deprecated and
no-ops — use `run_h3_graphql_query` for every read.** Read-only: never call `run_pentest` or any
mutation.

## An expired token registers ZERO tools — it never surfaces as a tool error

**Token TTL is ~24h in practice**, and when it lapses the server contributes **nothing to the
tool list**: no `mcp__horizon3__*` tool is registered, loaded or deferred, and nothing errors
because no call is ever possible. It reads as *this connector was never configured*, not as *this
connector is broken*, and can sit unnoticed for days — long enough to publish a report whose
Horizon3 section is silently empty.

- **Confirm with a bare unauthenticated request to the MCP URL.** It returns `HTTP 401` while the
  endpoint is otherwise healthy, which separates *expired credential* from *server down* in one
  call, with no tool registered and nothing to call in-band.
- **`authenticate` may or may not be exposed in a given session.** Where it is absent, re-auth
  cannot be self-served at all: it needs the operator's interactive OAuth against the connector,
  so say that plainly instead of retrying. Where it is present, it returns an OAuth URL that
  still needs the operator to complete it in a browser.
- **Preflight by tool presence, every run** — a missing Horizon3 answer is far more often zero
  tools than zero findings. The tool-agnostic form of this failure is in
  `working-with-mcp-connectors`; the `HTTP 401` probe above is the Horizon3-specific confirmation.

## Terminology gate (mandatory, and it's also your schema cheat-sheet)

- **Call `get_h3_terminology` FIRST, every session.** The MCP's own tool contracts require it,
  but the real reason is that it's the most reliable schema documentation available —
  introspection is broken (below). It defines the concept hierarchy *and* names field groupings
  (e.g. it reveals `remediation_guidance` decomposes into `fix_action` / `fix_action_description`
  / `fix_action_link`).
- Concepts that change how you report: **weakness** = *proven-exploitable* (not a theoretical
  vuln); **impact** = a business consequence NodeZero actually achieved; **attack_path** = a
  proven chain; **context_score** (0-10) = real-world exploitability — **rank on this, not CVSS
  base**.

## Reading a completed pentest

- **Easy path for locating + stats:** `get_pentest_details` (filter `text_search` /
  `completed_after` / `state`), then re-call with `include_vulnerabilities` /
  `include_attack_paths` / `include_credentials = true` on the `pentest_id`. Good for headline
  counts.
- **Query objects that exist:** `pentests_page`, `weaknesses_page(input:{op_id})`,
  `attack_paths_page(page_input)`, `credentials_page(input:{op_id})`. **There is NO
  `impacts_page` and NO `fix_actions_page`** — the `Query` type has neither (the "Did you mean"
  error confirms it). Read impacts via the pentest's `impacts_count` plus the attack-path
  objects, not a standalone page.
- **No API field returns a NodeZero console/portal URL** (`pentests_page` and
  `get_pentest_details` expose no link field). Hand a pentest to the user by `op_id` with "open
  it in the NodeZero Portal" — never a guessed console URL.

## Loot and proof artifacts do NOT expire in ~5 days

**This corrects a claim this skill used to carry**, and which is widely repeated elsewhere. It is
wrong, and acting on it produces a false urgency claim to the operator.

Measured against a live account: a complete `CommandOutputProofResource` — the command string plus
its full stdout — came back **intact 25 days after the pentest completed**, with every report
still listed.

- **No API field states any expiry.** There is no TTL, expires-at, or purge-at on a pentest,
  weakness, or proof object. The five-day number is not sourced from the API at all.
- **What is actually short-lived is the presigned download link, not the artifact.** Re-request the
  link and the artifact is still there. Never cache a presigned URL and read *its* expiry as the
  data's expiry.
- **An empty `proofs: []` array tracks weakness type, not age.** Some weakness classes simply carry
  no proof resource; absence of proof is not evidence that proof aged out.
- **Derive urgency from `next_triggered_at` on enabled schedules** — when the next run overwrites
  the picture — rather than from an imagined artifact TTL. "Pull this before it expires" is not a
  supportable statement about loot.

## The action log — the per-host command record

`action_logs_page` is the **complete log of every command NodeZero ran, per host** — the thing to
read for "what did it *try* against endpoint X," including attempts that never became findings.
It's not in the terminology cheat-sheet; get its exact shape from the public docs (below).

- **Shape:** `action_logs_page(input:{op_id:"…"}, page_input:{page_size:100,
  filter_by_inputs:[{field_name:"endpoint_ip", values:["10.0.0.5"]}]}) { action_logs {
  start_time end_time endpoint_ip cmd module_id module_name exit_code target_h3_names } }`.
- **Filtering is `page_input.filter_by_inputs: [FilterByInput]`**, each `{field_name, values,
  not_values, greater_than / greater_than_or_equal, less_than / less_than_or_equal, is_null}`. A
  bare `filter_by:{…}` object **crashes the server** with a generic "unexpected error" — it does
  not exist. Supported `field_name`s include `endpoint_ip`, `module_id`, `exit_code`, and the
  start/end times.
- **`page_size` caps at 100** (default 20); a larger value silently returns ≤100, so a
  `page_size:4000` pull looks like "the whole op" but is only the first ~100 rows (opening recon,
  sorted by `start_time` ascending). Paginate with `page_num` to walk the rest.
- **`exit_code` is the tool's exit, not exploitation success** — `0` means the module ran to
  completion, not that the target was compromised.
- **Attempted ≠ proven.** A blocked or failed exploit **appears in the action log but never
  becomes a `weaknesses_page` entry** and leaves `impacts_count: 0`. "Absent from weaknesses"
  means "not *proven*" — not "not *attempted*" and not "not *exploitable*"; a control (e.g. an EDR
  block) can suppress the callback NodeZero needs to score it. When a host's defensive posture is
  the question, read the action log, not just the weaknesses.

## Remediation — the trap that costs a re-run

- **Get remediation text from `weaknesses_page(input:{op_id}).weaknesses.vuln.description`.**
  That's where the usable fix guidance lives (e.g. a Jenkins CVE description spelling out the
  exploit mechanics and the fix version).
- **The `fix_action` / `fix_action_description` / `fix_action_link` fields are NOT exposed on the
  `Weakness` or `Vuln` GraphQL types** — despite `get_h3_terminology` advertising them.
  NodeZero's step-by-step fix actions are **portal/report-only**; don't promise them from the API.
- **Do NOT trust `get_vulnerability_details(include_remediation=true)`** — it reports remediation
  as "not available in current GraphQL schema," which mislabels the gap. The description *is*
  available via `weaknesses_page`; the helper just doesn't fetch it. Go to raw GraphQL.

## "Clean run" needs two corroborating fields, not one

A no-impact result is confirmed by **`impacts_count: 0` AND an empty `attack_paths` array
together** — treating either alone as "clean" risks reading a display/pagination gap as an
all-clear. NodeZero can reach 1,000+ hosts and harvest creds yet still chain zero proven impact;
that's the signal to report, with both fields cited.

But 0-impact is a *proven-results* statement, not a clean bill of health: if a control blocked an
exploit mid-run, the attempt still sits in the action log while `impacts_count` stays untouched —
cross-reference the action log (above) before reporting a host as unexposed.

## Pagination + filtering gotchas

- **`weaknesses_page` returns a default page (~20) — the full set can be several times larger.**
  Paginate for exhaustive enumeration; the severity *ceiling* and distinct classes are usually
  visible on page one, but counts are not.
- **`OpInput` (the `weaknesses_page` input) has `op_id` but no `severities` filter** — filter
  severity client-side after pulling.
- **Weakness fields that work:** `uuid`, `vuln_name`, `severity`, `score`, `ip`, `host_name`,
  `proofs`, and nested `vuln { id name description }`. Field-name traps: it's `host_name` not
  `hostname`, and `proofs` not `proof` (both miss with a "Did you mean" hint). `Vuln` has
  `description`, NOT `remediation`. `PageInfo` has no `total_count` — count client-side.

## Introspection is broken — the public docs portal is the fallback

- **Discover fields the MCP-native way first.** `get_h3_terminology` (the cheat-sheet — call it
  every session) plus the known-good field lists above plus incremental trial against the live
  query engine, which returns `Cannot query field 'X' on type 'Y'` and *sometimes* a `Did you
  mean 'Z'?` hint on scalar fields (not on every miss). **The "Did you mean" list is the fastest
  field-discovery path available** — e.g. `Cannot query field 'first_seen' on type
  'WeaknessSeries'. Did you mean 'first_seen_at', 'first_seen_date', or 'is_open'?` names three
  real fields in one failed call.
- **`fetch_h3_graphql_docs` DOES work — fetch a specific type, never `Query`.** (This corrects
  an earlier note here that said it errors server-side alongside `__type`.) `id: "Query"`
  returns roughly 133,000 characters and spills to a tool-results file; naming the type you
  actually need (`Schedule`, `PageInput`, `FilterByInput`, `WeaknessSeriesFacets`) returns
  inline and small. In-band `__type` introspection does still error ("An unexpected error
  occurred. We are investigating.").
- **When trial-and-error stalls, WebFetch the public docs: <https://docs.horizon3.ai/api/graphql/>.**
  They are fetchable and authoritative. Reach for them the moment probing isn't converging — a
  nested *input* shape crashes with a generic "unexpected error" and no field hint (e.g. the
  `filter_by_inputs` shape), which trial-and-error cannot recover on its own; the docs settle it
  in one shot. "Introspection is broken" is not "the schema is undiscoverable" — the HTML portal
  is the escape hatch.

## Weakness series — the account-wide view (the "Remediation Hub")

A single pentest's `weaknesses_page` is one op. The deduplicated, account-wide view used for
remediation, regression and trend tracking is a **different query family**, and requests naming
the Remediation Hub route here.

- **Root fields:** `weakness_series_page`, `weakness_series_count`, `weakness_series_facets` —
  alongside `pentests_page` and `schedules_page`. Note `pentests` is **not** a field.
- **Severity filter values are UPPERCASE, and the lowercase form returns 0 with NO error.**
  `filter_by_inputs: [{field_name: "severity", values: ["critical"]}]` returned **0**;
  `["CRITICAL"]` returned **269**. A silent-empty that reads exactly like a clean result.
  **Always read the real enum values off a `weakness_series_page` row before trusting any
  filtered count.**
- **`weakness_series_facets` has no severity facet** — use `weakness_series_count` with a filter
  instead (which is where the uppercase trap bites).
- **`WeaknessSeries` field traps:** `Cannot query field 'context_score' on type
  'WeaknessSeries'.` — context_score is a per-op weakness concept, not a series one. There is
  no `first_seen` either; the real names come back in the "Did you mean" hint (see
  "Introspection is broken" below).
- **`PageInput.page_num` is 1-indexed.** `page_num: 0` is rejected outright with
  `[400] Minimum allowed page number is 1.`

## Schedules

- **`Schedule` exposes `state` (`ENABLED` / `DISABLED`) and `is_disabled`, not `enabled`** —
  `Cannot query field 'enabled' on type 'Schedule'.`
- **`next_triggered_at` is NOT on `Schedule`.** It lives on `Schedule.run_pentest_action` (type
  `ScheduledAction`). "When does this run next" needs the nested object.

## Credentials + data

`credentials_page(input:{op_id})`, `cred_type` (e.g. `SNMP_COMMUNITY_STRING`, `STANDARD`).
**Report type and count only, never secret values.**

## Scope-awareness when reporting (don't overclaim)

An **internal network pentest** (e.g. "From <site> - 10.0.0.0/8") is **scope-disjoint from the
cloud-identity/control plane** — identity providers, cloud IAM roles, and CDN/WAF perimeter won't
appear and are outside its reach. A clean network pentest neither clears nor challenges those;
say so explicitly rather than letting "0 impacts" imply the identity plane is fine.

## What this skill does not cover

Running or scheduling pentests, writing findings, or investigating to a verdict — this is
read-only results reading.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
