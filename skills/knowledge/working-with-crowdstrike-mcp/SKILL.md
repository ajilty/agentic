---
name: working-with-crowdstrike-mcp
description: "CrowdStrike Falcon MCP (falcon_* tools). NG-SIEM CQL: head(3) schema discovery, groupBy(limit) truncating lexicographically (use top()), zero rows with job.processed_events 0 NOT being a negative, job.parsed_query dropping trailing stages, the repository param vs the #repo tag, numbers as strings, spill files, blocked processes under ProcessBlocked. FQL: a severity filter AND an is_closed:false filter EACH silently zero an endpoint queue whose rows carry score, no severity_name, and status new with is_closed true; aggregations drop records lacking the faceted field; cmdline wildcards return empty. Discover: broken pagination cursor, ~52x product-name over-count, and versions accumulating with NO row ever retired, so it cannot answer whether a vulnerable version is still installed; application rows carry an opaque host.id asset id that joins to a host only via falcon_search_managed_assets id:'<cid>_<assetid>', which rejects list syntax (`invalid filter; operator in not allowed for property id`). RTR: a session_id is mandatory (`1 validation error for run_read_only_command_and_waitArguments / session_id / Field required`) and rtr_state:enabled is policy not liveness (40401 Could not establish sensor comms). Plus alerts on journaled mail giving the envelope sender and a synthetic @journal.report.generator id, falcon_host_link varying by product, Spotlight blind spots. Use before an NG-SIEM query, triaging detections, deep-linking, making any software-version claim, joining an application row to a host, reading a mail alert, or running RTR — or on empty, truncated or mis-counted results."
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

**The `repository` parameter and the `#repo` tag are different namespaces, and mismatching them
returns a clean zero.** `#repo=third-party` with `repository: 'third-party'` returned 0 rows and
0 `processed_events`, while the same data resolved under `repository: 'search-all'` with the
vendor's own `#repo=<vendor>` tag. Read the real `#repo` value off a `head(3)` sample before
pinning either one.

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
- **Zero rows with `job.processed_events: 0` is NOT a confirmed negative** — nothing was
  scanned. A real negative is zero rows with `processed_events` greater than zero. The tool
  flags the ambiguous case itself, appending a hint plus the entire inline CQL guide to the
  response, which is easy to skim past. Read `processed_events` before reporting "nothing
  found", every time.
- **A short free-text token is not a filter, and the event counters prove it.** A two-character
  token piped into a `groupBy` scanned 215,686,423 events and returned the lexicographically
  first groups with no relation to the token, while the same query with a distinctive phrase was
  precise. **Compare `job.event_count` against `job.processed_events` before trusting any
  free-text aggregation**; anchor to fields (`Vendor.actor.alternateId=/x/i`) rather than
  matching the raw payload, which pulls in unrelated rows (192 groups returned where only 128
  mentioned the token anywhere).
- **`job.parsed_query` silently omits trailing `groupBy`/`sort` stages even when they
  demonstrably ran**, so it cannot be used to confirm an aggregation was applied. Confirm from
  the result shape instead.
- **A raw record dump overflows the token cap and spills to a file.** `<filter> | head(N)` for
  more than a handful of wide records blows past the MCP's max-token guard; the tool writes the
  full result to a `tool-results/*.txt` path and hands you the path, not the data. Two
  consequences: (1) **aggregate in-query** (`groupBy`/`top`/`count` on the few fields you need)
  instead of dumping full records; (2) when you *do* parse a spilled file, **the elements are
  not uniformly one-JSON-object-per-line** — a `jq -s '.[].text | fromjson'` pass dies because
  some `.text` elements are bare fragment lines (`"@id": …`), not whole objects. Guard each
  parse (`try fromjson`, or a `try/except json.loads` loop).
- **Calibration: 16 records can be enough to spill.** `falcon_search_detections` with
  `product:'automated-lead'` and `limit: 50` returned only **16** records and still blew the cap
  (100,500 characters, 2,156 lines). Automated-lead and automated-lead-context rows are very
  wide; lowering `limit` will not save you, so plan to parse the spill (`python3 json.load`)
  rather than to avoid it.

**Registry-ASEP telemetry (`AsepValueUpdate`, `investigate_view`) has no `ImageFileName`
field** — including it in a `groupBy` silently drops the column rather than erroring. The
writing process is `ContextProcessId`, which matches the detection record's `process_id`
exactly, so that is the reliable join from an alert to its registry telemetry.

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
- FQL combines predicates with `+` (AND), e.g. `status:'new'+created_timestamp:>'<iso>'`.
- `sort` accepts both `field.desc` and `field|desc`.
- **Neither a severity filter nor an open-items filter is a safe default on the endpoint
  detection queue — on some tenants either one silently returns zero.** Two independent causes,
  each sufficient on its own:
  - **`severity_name` may not exist on endpoint-native rows.** A tenant that emits no
    `product: epp` alerts carries its endpoint signal as `automated-lead` /
    `automated-lead-context` rows, and those carry a numeric **`score`** and **no
    `severity_name` at all**. `severity:>70`, `severity_name:'high'` and a `severity.desc` sort
    all drop the entire endpoint queue without an error.
  - **`is_closed` can be a schema artifact, not a triage state.** In the same tenant every
    automated lead reported the contradictory pair `status: 'new'` with `is_closed: true`, plus
    `seconds_to_resolved: 0` and `show_in_ui: true` — 16 of 16 records, no exceptions. So an
    `is_closed:false` "show me the open items" filter also returns zero, and `is_closed` carries
    no information about whether anyone has worked the row.
  Either filter alone therefore renders an untouched queue as a clean one. **Establish the
  population before filtering it:** `falcon_aggregate_detections` faceted on **`product`** and
  on **`source_vendors`** is the cheap call that shows the true split, and it is what tells you
  whether `severity_name` exists on the rows you care about. Build saved searches and daily
  triage on `product` + `created_timestamp`, not on severity or closure.
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

## Scheduled reports: there is no "was it read" signal

- **`falcon_search_report_executions` does not answer "did anyone open this report."** Falcon
  exposes no read or download state for a scheduled report at all; the delivery notification
  (e.g. into a chat channel) is the only observable, and it only proves the report *generated*.
- Worse, the tool is a token trap for that question: `status:'DONE'` with `limit: 15` returned
  153,800 characters across 1,207 lines and spilled to a tool-results file, and the payload is
  almost entirely **XDR correlation-rule execution metadata**, not the scheduled-report records
  you were looking for. Filter by the report id, or don't call it.

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
- **The inventory accumulates versions and never retires a row.** One host listed **three major
  versions of the same product simultaneously**, long after two of them had been uninstalled.
  Discover records what was **ever** installed, not what **is** installed: there is no removal
  event, no last-seen decay, and no field separating resident-but-dead from active. Two
  consequences. (1) It **cannot answer "are we still running the vulnerable version"** — it
  returns that false positive indefinitely, and a patched host is indistinguishable from an
  unpatched one. (2) An in-place upgrade that leaves old component directories resident looks
  identical to a host that never upgraded. So the oldest version on a host is a **risk flag to go
  check**, never a version claim. **Confirm on-host** (RTR `filehash` / running-process
  telemetry) before stating any version, and never open *or* close a remediation ticket on
  Discover alone.

## falcon_search_managed_assets (joining an application row back to a host)

- **An application record's `host.id` is an opaque asset id, not the 32-hex device id** the hosts
  API returns. The two identifier spaces do not overlap, so handing a `host.id` to a host-scoped
  call matches nothing — silently, as an empty result rather than an error. Join through managed
  assets on the **composite** form: `id:'<cid>_<assetid>'` (customer id, underscore, the asset id
  off the application row). Without that join, an "installed on N hosts" answer has no hostnames
  attached to it.
- **The `id` property rejects list syntax**, verbatim:
  `invalid filter; operator in not allowed for property id`. This one is a hard error, not the
  usual silent empty — `id:[...]` never works. Use FQL's comma-OR'd equality instead:
  `id:'<a>',id:'<b>'`, several ids per call, rather than one call per asset.

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

- **`falcon_run_rtr_read_only_command_and_wait` requires a `session_id` and will not open a
  session from `device_id` alone.** Verbatim:
  `1 validation error for run_read_only_command_and_waitArguments / session_id / Field required`.
  There is no implicit session and no device-id shortcut — call `falcon_init_rtr_session` on the
  host first, carry its `session_id` into every command, and delete the session when done.
- **The read-only command set cannot read a PE file's version property** (that needs the
  Active-Responder scripting tier / `runscript`). To identify a binary's build read-only, use
  `filehash` (SHA256/MD5) and map the hash via the software inventory, or `reg query` an app's
  version value — not the file version. A vendor's registry key may not carry a build value
  (`HKLM\SOFTWARE\Veeam\Veeam Backup and Replication` held only `TempPathDir` and provider GUIDs,
  no version).
- **`init` returns the full command schema** for the host (base command set + args), and reports
  `offline_queued: false` when the host is live; **delete the session**
  (`falcon_delete_rtr_session`) when done.
- **`rtr_state: enabled` on a host record is a policy capability, not a liveness signal.**
  `falcon_init_rtr_session` against a host that is not currently checked in returns HTTP 404
  with `errors[0].code` `40401` and message `Could not establish sensor comms`, even though the
  host record says RTR is enabled. **Compare `last_seen` against now before planning any RTR
  step**, and expect laptops to be unreachable outside working hours — an RTR-dependent plan
  written off `rtr_state` alone will fail at execution time, not at planning time.

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
  → delivery), plus one `MailItemsAccessed` per open. The inflation factor depends on your
  journaling and gateway config. `Status: Expanded` marks distribution-list fan-out, not a
  delivery.
- **Message-ID is NOT a safe dedupe key across journal legs** (this corrects the earlier advice
  here to dedupe on message-ID + recipient). Two journal forks of one message carry **different
  synthetic Message-IDs and different `aggregateId`s**, so a Message-ID dedupe leaves both in
  and undercounts nothing while over-counting the message. The journaling fork is identifiable
  by **three co-occurring markers, not one**: a Message-ID ending `@journal.report.generator`,
  a recipient at the archiver's own ingest domain, and a `senderEnvelope` that is the journaling
  address rather than the author. The reliable dedupe key across legs is **sender header +
  subject + attachment hash**.
- **A journaled message's alert names the envelope, not the author.**
  `falcon_get_detection_details` on a third-party mail alert returns `sender` = the SMTP
  **envelope** sender and `message_id` = the journal report's **synthetic** id
  (`…@journal.report.generator`) — never the original message's `From` or `Message-ID`. The
  field that separates the real originator from the journaling envelope is **`senderHeader`**,
  and it is **absent from the Falcon alert record entirely**; it lives in the NG-SIEM row's
  `@rawstring`. Reading direction, sender or recipient off the Falcon alert alone gives the
  wrong answer on any journaled message — which is how a reported inbound phish reads as an
  outbound lure from your own user.
- **Keep `@rawstring` evidence inline with `select()`.** Mail-gateway rows carry the whole
  vendor record inside `@rawstring`, so a free-text search plus `head(20)` spilled at 74,725
  characters; `… | select([@timestamp, @rawstring])` returns the same evidence at a fraction of
  the size.
- **A gateway hold emits a delivery row for the hold NOTICE, under the same `aggregateId`.** The
  hold itself logs as an `emailsecurity.process` action `Hld`; the follow-on
  `emailsecurity.delivery` row is the postmaster notification to the recipient, not the message.
  Reading it as proof of delivery is wrong — check `Vendor.recipients` and `Vendor.subject` on
  the delivery row (a hold notice shows a postmaster sender, a "suspicious files" subject,
  `emailSize: 0` and `numberAttachments: 0`).
- **A Message Trace dataset can cover only some of a tenant's accepted domains.**
  `#event.dataset=messagetrace.event` returned zero rows for one accepted domain across ~80,000
  events in 1.5 days — flagged by the API as a real negative, not an empty scan. Any
  absence-of-evidence conclusion from Message Trace is valid **only for the domains actually
  present**; `groupBy` the recipient domain first and say which ones you covered.
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
