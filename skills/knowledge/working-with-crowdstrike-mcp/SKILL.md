---
name: working-with-crowdstrike-mcp
description: "CrowdStrike Falcon MCP (falcon_* tools): NG-SIEM CQL gotchas \u2014 head(3) schema discovery, groupBy limit truncates lexicographically (use top()), numbers as strings, token-overflow spill files, blocked processes logged under ProcessBlocked not ProcessRollup2 \u2014 plus FQL syntax, falcon_aggregate_detections silently dropping records that lack the faceted field (pass missing), the free-text q param being a fuzzy multi-token OR match, falcon_host_link paths differing by product (unified-detections vs activity-v2/detections vs automated-leads) and hosts/vulns exposing no console link at all, detection write-path traps, the falcon_search_applications (Discover) broken pagination cursor and ~52x product-name over-count, the Spotlight (falcon_search_vulnerabilities) no-product-filter limit, its rejection of host_info.hostname, and its zero-coverage blind spots for whole third-party product classes, and RTR read-only limits. Use before composing falcon_search_ngsiem queries, counting a detection queue, building a console deep-link, paging Discover applications, scoping Spotlight vulns, reading blocked-process telemetry, or running RTR \u2014 or when results come back empty, truncated, mis-counted, or spilled to tool-results files."
---

# Working with the CrowdStrike Falcon MCP — sharp edges

How to drive `falcon-mcp` efficiently and correctly. This is about operating the tool; what
specific log fields *mean* belongs in your own per-source notes.

## falcon_search_ngsiem (CQL / LogScale dialect)

**The tool runs CQL; it does not help you write it.** You must supply a complete, valid query.
There is no query-builder assist — a malformed query just fails or returns nothing.

### Discover the schema before you aggregate

Field names vary by parser version and data source — **never assume them**. Sample first:

```
<filter> | head(3)
```

Read the real field names off a couple of records, *then* write the `count()`/`top()`. A
`top(some_field)` against a field that doesn't exist returns **empty with no error**, which looks
like "no data" and wastes a round-trip.

Also check for sampling: some sources (e.g. Cloudflare Magic Firewall, `#Vendor=cloudflare`)
carry a `SampleInterval` — logged event counts understate actual rates by that factor; say so
when reporting rates.

### Filter on indexed tags, not free text

Tag fields are in the segment index; raw-payload free text is not. Prefer
`#repo=<repo> #event.dataset=<ds> event.action=blocked` over a bare free-text token. Common
tags: `#repo`, `#Vendor`, `#type`, `#event.dataset`, `#event.module`, `#event.kind`.

### Pick the right repository

The `repository` param scopes the search and speeds it up: `search-all` (default, slowest),
`third-party` (ingested feeds — proxy, SaaS, cloud audit connectors; contents vary by estate),
`investigate_view` (endpoint events), `falcon_for_it_view`, `forensics_view`. Learn what your
estate routes into `third-party` — connector-fed audit logs there (e.g. GitHub enterprise) can
give enterprise-wide visibility that per-API queries can't.

### Time + timeout

- `start` is **required**, ISO-8601 (`2026-05-25T00:00:00Z`). `end` defaults to now.
- Searches time out at `FALCON_MCP_NGSIEM_TIMEOUT` (default **300s**). Narrow the window and add
  filters before widening; don't open a 30-day `search-all` as a first move.

### Aggregation idioms that pay off

- `top(field, limit=N)` → ranked frequency table with an auto `_count` column. The fastest way
  to find outliers.
- `groupBy([f1, f2], function=count())` → cross-tab over multiple fields.
- **`groupBy(field, limit=N)` does NOT keep the top-N by count — it keeps the
  lexicographically-first N groups, and a trailing `sort()` only ranks that already-truncated
  subset.** So `groupBy(user.name, limit=25) | sort(_count, order=desc)` on a high-cardinality
  field silently drops every group after the first 25 *alphabetically* — the real highest-count
  value never enters the candidate set, and the result looks plausible but is wrong. For
  "who/what has the most," use `top(field, limit=N)`. Reserve `groupBy(…limit…)` for when you
  want *all* groups — set the limit above the true cardinality.
- `timechart(span=1h, series=field)` → time buckets (`_bucket` is epoch-ms). A flat overnight
  floor vs a diurnal shape distinguishes automation from human activity; a clean step-and-hold
  cliff is a *config* change while a human tapers raggedly — the **shape of the transition is
  itself evidence of the cause**.
- `sum(field, as=name)` → totals (e.g. bandwidth from a transaction-size field).
- Always cap exploration with `head()`; aggregate rather than dumping raw rows.

### Result-shape gotchas

- **Numbers come back as strings** (`"_count": "2773932"`). Cast before doing math.
- **Large spilled results carry no `total` field** — a spill file's record count is not the
  query's total; re-run with an in-query `count()` if the total matters.
- A single-row `top()` when you expected a distribution is **signal, not failure**: the behavior
  is entity-specific (one host/user), which redirects the investigation.
- Empty output ≠ no data — first suspect a wrong field name or wrong `repository`.
- **A raw record dump overflows the token cap and spills to a file.** `<filter> | head(N)` for
  more than a handful of wide records blows past the MCP's max-token guard; the tool writes the
  full result to a `tool-results/*.txt` path and hands you the path, not the data. Two
  consequences: (1) **aggregate in-query** (`groupBy`/`top`/`count` on the few fields you need)
  instead of dumping full records; (2) when you *do* parse a spilled file, **the elements are
  not uniformly one-JSON-object-per-line** — a `jq -s '.[].text | fromjson'` pass dies because
  some `.text` elements are bare fragment lines (`"@id": …`), not whole objects. Guard each
  parse (`try fromjson`, or a `try/except json.loads` loop).

### Blocked / prevented actions log under their own event, not the usual one

A prevention-blocked process is **not** in `ProcessRollup2` — it lands in
`#event_simpleName=ProcessBlocked` (carrying the full `CommandLine`, `ImageFileName`, and
`ParentBaseFileName`). So a `ProcessRollup2 ParentBaseFileName=<x>` query returning **zero
children is not "no telemetry"** — the blocked child executed far enough to be recorded, just
under `ProcessBlocked`. When a detection shows a prevention/block, query `ProcessBlocked` for the
command line and parent. Check the block-specific event name before concluding the sensor saw
nothing.

`ProcessRollup2` does **not** reliably populate `FileVersion` for every binary (third-party
service exes especially) — a `groupBy([ComputerName, FileVersion], …)` silently drops the column
when it's empty. To pin a binary's build, key on `SHA256HashData` and map the hash via the
software inventory (`falcon_search_applications`) or RTR `filehash`, not `FileVersion`.

### CQL construction gotchas

- **`OR` across two `regex()` calls → HTTP 400.** Reformulate as field-match alternation
  (`field=/.../i or field=/.../i`) rather than chaining `regex(...)` OR `regex(...)`.
- **`falcon_search_detections`'s free-text `q` param works, but it is a fuzzy multi-token OR
  match** — this corrects an earlier note here that claimed it resolves to a null filter. A
  single-token `q` is usable (a positive control returned 225 rows); a multi-token `q` returns
  large numbers of unrelated rows, because the tokens are OR'd. Trust single-token results only,
  and prefer explicit FQL field filters (`sha256:`, `device.hostname:`, `pattern_id:`) whenever
  the field exists. Validate any empty `q` result against a positive control before reporting it
  as a negative.
- **CVE FQL is dotted: `cve.id:'…'`, not bare `cve:'…'`** — the bare form returns HTTP 400
  across the vuln/intel tools.
- **A clean-empty result for a fresh CVE is the CORRECT answer, not an error.** Differentiate by
  **response shape**: a well-formed query returns an empty set (HTTP 200, empty array); a wrong
  field name or bad syntax returns a 400. Don't retry an empty-but-valid result as if it failed.
- **Anchor regexes when a substring can collide.** A case-insensitive `useragent=/iOS/i` matches
  `axios/1.15.2` and silently pulls the wrong platform into the filter. Use an exact-value pivot
  or anchor the pattern (`/^iOS\//`).
- **Render times with the tz database, sort on the raw field:**
  `formatTime(@timestamp, timezone="<your tz>")`, and **sort on `@timestamp`, not the formatted
  string** — this delegates DST handling instead of hardcoding an offset.

### Parallelize independent queries

Independent breakdowns (by action, by destination, a timechart) have no dependencies — issue
them as **multiple tool calls in one message**. Only serialize when a later query needs an
earlier one's output (e.g. `head(3)` to learn field names before `top()`).

## search_* FQL tools (detections, hosts, incidents, cases, ...)

- These take **FQL**, not CQL — different syntax. Many have a companion FQL guide resource
  (`falcon://<domain>/.../fql-guide`); consult it before composing non-trivial filters.
- FQL combines predicates with `+` (AND), e.g. `status:'new'+severity:>70`.
- `sort` accepts both `field.desc` and `field|desc`; sort `severity.desc` to surface the worst
  first.
- **A `cmdline:'*substring*'` wildcard filter on `falcon_search_detections` /
  `falcon_aggregate_detections` returns empty silently** — `cmdline` is not a supported
  filter/aggregation field on the alerts endpoint (empty ≠ no match). Pivot to an indexed field:
  `pattern_id:`, `technique_id:`, `tags:`, or a time-boxed `created_timestamp:`.
- **`falcon_aggregate_detections` silently drops records that lack the faceted field.** A facet
  on `severity_name` summed to **237 against a `pagination.total` of 253**, and
  `sum_other_doc_count` reported **0**, so nothing flagged the 16-record shortfall — the missing
  rows simply had no `severity_name`. Pass the **`missing`** parameter to bucket them. Any queue
  count built on this aggregation without it under-reports invisibly; cross-check the facet sum
  against `pagination.total` every time.
- **A detection's `automated_triage` block (Charlotte) is a fast first-pass anchor** —
  `triage_outcome` / `triage_recommendation` plus tags like `FC-Type-Penetration Testing`,
  `true_positive`, `FC-Action-No Remediation Required` often classify the alert (e.g. authorized
  pentest activity) before you dig; `falcon_get_detection_details` returns them.

## falcon_search_applications (Discover software inventory)

Discover is the authoritative on-disk software inventory — reach for it (not Spotlight, not
process telemetry) to answer "where is product X installed."

- **The pagination `after` cursor is broken: it re-serves page 1.** Passing `pagination.next`
  back as `after` returns the same first page, so a naive paging loop silently caps at one page
  and looks complete. **Recover the full set by unioning two opposite sorts** (e.g. `name.asc`
  then `name.desc`, or on `last_updated_timestamp`) and deduping on the row `id` — between them
  you cover the whole set up to 2× the page size. `pagination.total` still reports the true
  count, so you know when you have them all.
- **A `name:'*Product*'` wildcard over a widely-installed product spills to a
  `tool-results/*.txt` file** (agent/console footprints put the product on hundreds of hosts).
  Parse the spill with `python3 json.load` on the `results` key; don't read it inline.
- **Discover normalizes many components under one product name.** Every Veeam service (Agent,
  console, Mount Service, Transport) reports as `name: "Veeam Backup & Replication"`, so a raw
  host count conflates the real servers with hundreds of agent-only workstations — filter on
  `host.product_type_desc` and read the component-level names, not the rolled-up product.
  **Order of magnitude, measured:** one product returned **263 distinct hosts** where only **5**
  ran the actual server role, a ~52x over-count. Taking the product-name count at face value
  produces a wildly over-scoped affected-host list. **Diff two inventories** — Discover
  (installed) against running-process telemetry (actually executing, with full paths) — and
  treat the disagreement as the finding rather than trusting either alone.
- **A host lists multiple co-existing versions** (an in-place upgrade leaves old component
  directories resident), so the *oldest* version on a host is a risk flag, not proof the old
  build is the active one — confirm on-host (RTR `filehash` / running-process telemetry) before
  calling it live-vulnerable.

## falcon_search_vulnerabilities (Spotlight)

- **The FQL has no product / vendor / app filter field.** You cannot filter to "all of vendor
  X's CVEs" by product — reach a third-party product only by **enumerating its known CVE IDs**
  (`cve.id:'CVE-…',cve.id:'CVE-…'`). Consult `falcon://spotlight/vulnerabilities/fql-guide`; an
  unsupported field returns empty, not an error.
- **Spotlight under-inventories third-party software, and the gap can be total.** It reported
  one product on 1 of ~50 hosts that Discover and process telemetry both show running it. Worse
  was later measured on another product: **zero findings tenant-wide**, including **zero on the
  dedicated server running 16 of that product's services**, while the same host returned 96
  findings covering two other vendors. The scanner was scanning that host and returning plenty;
  it simply had **no evaluation logic for that product class** in the tenant. So the failure mode
  is per-product, not per-host: a host with many findings can still be completely unassessed for
  a given product. Combined with the no-product-filter limit above, you cannot even ask the
  question. Do **not** use Spotlight to scope a software estate (use
  `falcon_search_applications`), and never accept "no Spotlight CVE" as evidence for a
  non-Microsoft product — including as an acceptance criterion on a remediation ticket.
- **Spotlight FQL rejects `host_info.hostname`** with HTTP 400, verbatim
  `property "host_info.hostname" not allowed`. Scope a host with **`aid`** instead (resolve it
  first via `falcon_search_hosts`).
- **`status:'reopen'` is a real signal** — a finding remediated then re-detected means a patch
  regressed or was incomplete; worth a root-cause check, not just a re-patch. Facet
  `['cve','host_info']` to get scoring + asset context in one call.

## Real Time Response (RTR) — read-only tier

- **The read-only command set cannot read a PE file's version property** (that needs the
  Active-Responder scripting tier / `runscript`). To identify a binary's build read-only, use
  `filehash` (SHA256/MD5) and map the hash via the software inventory, or `reg query` an app's
  version value — not the file version. A vendor's registry key may not carry a build value
  (`HKLM\SOFTWARE\Veeam\Veeam Backup and Replication` held only `TempPathDir` and provider GUIDs,
  no version).
- **`init` returns the full command schema** for the host (base command set + args), and reports
  `offline_queued: false` when the host is live; **delete the session**
  (`falcon_delete_rtr_session`) when done.

## Write path and console deep-links

- **Console deep-link: use the detection's own `falcon_host_link` field, verbatim.** Do **not**
  hand-build a `…/unified-detections/?filter=…&info=<id>` URL — it renders an **unfiltered**
  detections page, not the target detection.
  - **The path varies by `product`, so there is no one shape to template**:
    `/unified-detections/<composite_id>?_cid=<code>` for `product: thirdparty`,
    `/activity-v2/detections/<composite_id>?_cid=<code>` for `product: epp` (endpoint), and
    `/automated-leads/<composite_id>?_cid=<code>` for signal / automated-lead rows. Templating
    the third-party shape across an endpoint detection produces a **dead link that still looks
    right**. Emit the field per row.
  - **Only detections carry a link.** `falcon_search_hosts` returns no URL-shaped field at all,
    so a host is reachable only via some detection's `falcon_host_link`. On
    `falcon_search_vulnerabilities`, `remediation.entities[].link` was present but an **empty
    string**, while `remediation.entities[].vendor_url` and `cve.vendor_advisory[]` hold
    *external vendor* URLs — none of the three is a console deep-link.
- **`falcon_update_detections` (status / resolution tag / comment / assignment)** works and is
  batchable (many `ids` per call). Gotchas:
  - The top-level **`comment` rollup field returns word-scrambled** — read the structured
    **`comments[]` array** instead (each entry has `falcon_user_id`, `timestamp`, `value`).
  - Comments post under the **API-client identity**, not the human — name the human in the
    comment text if attribution matters.
  - Resolution is **tag-based**: apply `true_positive` / `false_positive` / `ignored` to
    populate the console's Resolution column; `status:closed` alone does not.

## Correlation edges for commonly-ingested sources (adapt to your estate)

These are observed patterns from specific vendor pairings (M365 audit, mail gateways, Zscaler
ZIA). They apply only where your estate ingests the same sources — treat them as worked
examples, and keep your own per-source field notes for the rest.

- **Microsoft 365 / Exchange audit in NG-SIEM:** Defender-passthrough detections in Falcon carry
  no target mailbox or operation — the NG-SIEM pivot into the M365 audit rows is mandatory, not
  an enrichment. Admin-account actor UPNs in Exchange audit use the tenant's
  `<tenant>.onmicrosoft.com` domain — a primary-domain filter silently misses them. Subjects are
  nested (`Vendor.Folders[N].FolderItems[M].Subject`), not flat — `head(3)` first.
- **Mail-flow count inflation is the norm; dedupe before reporting.** One logical message
  produces many rows: one Message Trace `Delivered` per recipient leg, a duplicate for any
  journaling/archiving compliance fork, a multi-stage gateway pipeline (receipt → spam → process
  → delivery), plus one `MailItemsAccessed` per open. Dedupe on message-ID + recipient; the
  inflation factor depends on your journaling and gateway config. `Status: Expanded` marks
  distribution-list fan-out, not a delivery.
- **Tenant boundary:** the SIEM sees only legs that touch your tenant — an external
  participant's intra-external hops are invisible. `MailItemsAccessed` proves *a client fetched
  it*, not *a human saw it*; `MailAccessType` `Bind` (explicit open) vs `Sync` (background pull)
  disambiguates.
- **Zscaler ZIA ↔ Falcon sensor join:** `zia.web` rows are pre-enriched with the device's Falcon
  AID (`source.Id`/`client.Id` *is* the sensor `aid`) — an exact join, not a fuzzy hostname
  match. The trap: on a tunnel-client host, endpoint DNS/NetworkConnect telemetry attributes
  egress to the tunnel process (`ZSATunnel.exe`), not the real browser — proxy UA and endpoint
  network layer diverge, and naming the exact originating process definitively needs RTR live
  (`rtr_state: enabled`); everything short of that is strong inference, not proof.
- **Web requests double-log through a decrypting proxy:** a CONNECT to `host:443` with the
  tunnel UA, then the decrypted request with `useragent="Unknown"`. For one row per session,
  filter on the CONNECT leg (e.g. `url=/:443$/`).

## What this skill does not cover

Exhaustive per-source field semantics — beyond the worked correlation examples above, what a
given vendor's fields mean belongs in your own data-source notes.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
