---
name: working-with-crowdstrike-mcp
description: "CrowdStrike Falcon MCP (falcon_* tools: falcon_search_ngsiem, falcon_search_detections, falcon_aggregate_detections, falcon_get_detection_details, falcon_update_detections, falcon_search_applications, falcon_search_managed_assets, falcon_search_vulnerabilities, falcon_search_hosts, falcon_search_report_executions, falcon_init_rtr_session, falcon_run_rtr_read_only_command_and_wait). Use before writing CQL or FQL, when a result is empty, truncated, mis-counted, or spilled to tool-results/*.txt, and on: job.processed_events 0, groupBy(limit) vs top(), job.parsed_query, repository param vs #repo tag, ProcessBlocked, AsepValueUpdate, FileVersion missing, severity_name absent on automated-lead rows, is_closed true with status new, cmdline wildcard, sum_other_doc_count 0 with a facet shortfall, pagination after cursor re-serving page 1, host.id vs device id, `invalid filter; operator in not allowed for property id`, `property host_info.hostname not allowed`, `session_id / Field required`, 40401 `Could not establish sensor comms`, rtr_state enabled, falcon_host_link, @journal.report.generator, senderHeader, SampleInterval, zia.web, ZSATunnel.exe."
---

# Working with the CrowdStrike Falcon MCP — sharp edges

Operating the tool, not what a vendor's fields mean (keep those in your own per-source notes).

## falcon_search_ngsiem (CQL / LogScale)

The tool runs CQL and offers no assist: a malformed query fails or returns nothing, and empty
output is first a wrong field name or wrong `repository`, not "no data".

- **Sample before you aggregate**: `<filter> | head(3)`, read the real field names, then
  `top()`/`count()`. `top(missing_field)` returns empty with no error. Note `SampleInterval` on
  sampled sources (e.g. `#Vendor=cloudflare` Magic Firewall) and scale rates by it.
- **Filter on indexed tags**, not raw text: `#repo=<repo> #event.dataset=<ds> event.action=blocked`.
  Tags: `#repo`, `#Vendor`, `#type`, `#event.dataset`, `#event.module`, `#event.kind`.
- **`repository` param** scopes and speeds the search: `search-all` (default, slowest),
  `third-party` (connector feeds: proxy, SaaS, cloud audit; e.g. GitHub enterprise audit there
  gives estate-wide visibility per-API queries cannot), `investigate_view` (endpoint),
  `falcon_for_it_view`, `forensics_view`. **It is a different namespace from the `#repo` tag**:
  `#repo=third-party` with `repository: 'third-party'` returned 0 rows and 0 `processed_events`;
  the data resolved under `repository: 'search-all'` with the vendor's own `#repo=<vendor>`. Read
  `#repo` off `head(3)` before pinning either.
- `start` is required, ISO-8601 (`2026-05-25T00:00:00Z`); `end` defaults to now. Timeout is
  `FALCON_MCP_NGSIEM_TIMEOUT` (default 300s): narrow and filter before widening; no 30-day
  `search-all` as a first move.
- **Idioms**: `top(field, limit=N)` (ranked, auto `_count`); `groupBy([f1, f2], function=count())`
  cross-tab; `timechart(span=1h, series=field)` (`_bucket` is epoch-ms; a flat overnight floor is
  automation, a step-and-hold cliff is a config change, a ragged taper is a human: the transition
  shape is evidence); `sum(field, as=name)`. Cap exploration with `head()`; aggregate, don't dump.
- **`groupBy(field, limit=N)` keeps the lexicographically-first N groups, not the top N by
  count**, and a trailing `sort()` ranks only that subset:
  `groupBy(user.name, limit=25) | sort(_count, order=desc)` silently drops the true maximum. Use
  `top(field, limit=N)` for "most"; use `groupBy(…limit…)` only with the limit above cardinality.
- Independent breakdowns have no dependency: issue them as multiple tool calls in one message;
  serialize only when one needs another's output (`head(3)` before `top()`).

### Reading results

- Numbers are strings (`"_count": "2773932"`): cast before math. Spilled results carry no
  `total`; re-run with an in-query `count()` if it matters. A single-row `top()` is signal
  (entity-specific behavior), not failure.
- **Zero rows with `job.processed_events: 0` is not a negative**: nothing was scanned; a real
  negative has `processed_events > 0`. The tool flags this by appending a hint plus the whole
  inline CQL guide, which is easy to skim past. Read `processed_events` before reporting
  "nothing found".
- **A short free-text token is not a filter.** A two-character token into `groupBy` scanned
  215,686,423 events and returned lexicographically-first groups unrelated to the token (192
  groups where 128 mentioned it); a distinctive phrase was precise. Compare `job.event_count`
  against `job.processed_events` before trusting any free-text aggregation, and anchor to fields
  (`Vendor.actor.alternateId=/x/i`).
- **`job.parsed_query` omits trailing `groupBy`/`sort` stages that demonstrably ran**; confirm
  aggregation from the result shape.
- **Spills**: a wide `head(N)` overflows the token cap and the tool returns a `tool-results/*.txt`
  path instead of data. Aggregate in-query. When parsing a spill, elements are not
  one-JSON-object-per-line: `jq -s '.[].text | fromjson'` dies on bare fragment lines
  (`"@id": …`), so guard each parse (`try fromjson`, or `try/except json.loads`). Calibration:
  `falcon_search_detections` with `product:'automated-lead'`, `limit: 50` returned 16 records and
  still spilled (100,500 chars, 2,156 lines); lowering `limit` will not save you, plan to parse
  (`python3 json.load`).

### Endpoint telemetry fields

- **A blocked process lands under `#event_simpleName=ProcessBlocked`** (full `CommandLine`,
  `ImageFileName`, `ParentBaseFileName`), not `ProcessRollup2`: zero `ProcessRollup2` children of
  a parent is not "no telemetry" when the detection shows prevention.
- `ProcessRollup2` does not reliably populate `FileVersion`; `groupBy([ComputerName, FileVersion], …)`
  silently drops the empty column. Pin a build by `SHA256HashData` mapped via
  `falcon_search_applications` or RTR `filehash`.
- `AsepValueUpdate` (`investigate_view`) has no `ImageFileName`; a `groupBy` including it silently
  drops the column. The writer is `ContextProcessId`, which equals the detection's `process_id`
  exactly: that is the alert-to-registry join.

### CQL construction

- `OR` across two `regex()` calls is HTTP 400; write `field=/.../i or field=/.../i`.
- Anchor regexes where a substring collides: `useragent=/iOS/i` matches `axios/1.15.2`; use
  `/^iOS\//` or an exact value.
- Render times with `formatTime(@timestamp, timezone="<your tz>")` and sort on `@timestamp`, not
  the formatted string (delegates DST).
- Keep `@rawstring` evidence inline with `… | select([@timestamp, @rawstring])`: a free-text
  search plus `head(20)` on mail-gateway rows spilled at 74,725 chars; `select()` returns the same
  evidence at a fraction.

## search_* / aggregate_* FQL tools (detections, hosts, incidents, cases, ...)

- FQL, not CQL; each domain has a `falcon://<domain>/.../fql-guide` resource. `+` is AND
  (`status:'new'+created_timestamp:>'<iso>'`); `sort` takes `field.desc` or `field|desc`. A
  well-formed query with no matches is HTTP 200 and an empty array; a bad field or syntax is
  400. So a clean-empty for a fresh CVE is the correct answer, not a retry.
- **Neither a severity filter nor an open-items filter is a safe default on the endpoint
  detection queue**; each alone silently zeroes it. (1) A tenant emitting no `product: epp`
  alerts carries endpoint signal as `automated-lead` / `automated-lead-context` rows with a
  numeric `score` and no `severity_name`, so `severity:>70`, `severity_name:'high'` and a
  `severity.desc` sort drop the whole queue. (2) `is_closed` can be a schema artifact: every
  automated lead (16 of 16) reported `status: 'new'` with `is_closed: true`,
  `seconds_to_resolved: 0`, `show_in_ui: true`, so `is_closed:false` also returns zero and says
  nothing about triage. Establish the population first with `falcon_aggregate_detections`
  faceted on `product` and `source_vendors`; build triage on `product` + `created_timestamp`.
- **`falcon_aggregate_detections` drops records lacking the faceted field** with no flag: a
  `severity_name` facet summed to 237 against `pagination.total` 253 with `sum_other_doc_count`
  0. Pass `missing` to bucket them and cross-check facet sum against `pagination.total` every time.
- `cmdline:'*substring*'` on `falcon_search_detections` / `falcon_aggregate_detections` returns
  empty silently (unsupported field). Pivot to `pattern_id:`, `technique_id:`, `tags:`, or a
  time-boxed `created_timestamp:`.
- **`falcon_search_detections` `q` is a fuzzy multi-token OR match** (this corrects an earlier
  note that it resolves to a null filter). Single-token `q` is usable (positive control: 225
  rows); multi-token returns unrelated rows. Prefer `sha256:`, `device.hostname:`, `pattern_id:`;
  validate any empty `q` against a positive control before reporting a negative.
- CVE FQL is dotted, `cve.id:'…'`; bare `cve:'…'` is HTTP 400 across the vuln/intel tools.
- `falcon_get_detection_details` returns the `automated_triage` block (`triage_outcome`,
  `triage_recommendation`, tags like `FC-Type-Penetration Testing`, `true_positive`,
  `FC-Action-No Remediation Required`): a fast first-pass classifier.
- **`falcon_search_report_executions` cannot say whether a report was read** (Falcon exposes no
  read/download state; the delivery notification only proves generation) and is a token trap:
  `status:'DONE'`, `limit: 15` spilled 153,800 chars / 1,207 lines of XDR correlation-rule
  execution metadata. Filter by report id or skip it.

## falcon_search_applications (Discover)

Discover is the authoritative *ever-installed* inventory: use it (not Spotlight, not process
telemetry) for "where is X installed", within these limits.

- **The `after` cursor re-serves page 1** (passing `pagination.next` back as `after`), so a paging loop caps at one page and looks complete.
  Union two opposite sorts (`name.asc` then `name.desc`, or on `last_updated_timestamp`) and
  dedupe on `id`; that covers up to 2x page size, and `pagination.total` is still true.
- `name:'*Product*'` over a widely-installed product spills; parse the `results` key with
  `python3 json.load`.
- **Component roll-up over-counts ~52x**: every Veeam component (Agent, console, Mount Service,
  Transport) reports `name: "Veeam Backup & Replication"`; 263 distinct hosts where 5 ran the
  server role. Filter `host.product_type_desc`, read component-level names, and diff Discover
  against running-process telemetry: the disagreement is the finding.
- **No row is ever retired**: one host listed three major versions long after two were
  uninstalled. No removal event, no last-seen decay, so it cannot answer "are we still running the
  vulnerable version" and a patched host is indistinguishable from an unpatched one. The oldest
  version is a risk flag to check on-host (RTR `filehash`, process telemetry); never open or
  close a remediation ticket on Discover alone.

## falcon_search_managed_assets (application row to host)

- An application row's `host.id` is an opaque asset id, not the 32-hex device id; handing it to
  a host-scoped call returns empty silently. Join via `id:'<cid>_<assetid>'`.
- `id` rejects list syntax (`id:[...]`) with a hard error, `invalid filter; operator in not allowed for property id`;
  use comma-OR equality, `id:'<a>',id:'<b>'`, several per call.

## falcon_search_vulnerabilities (Spotlight)

- No product/vendor/app filter field; reach a product only by enumerating CVEs:
  `cve.id:'CVE-…',cve.id:'CVE-…'` (guide: `falcon://spotlight/vulnerabilities/fql-guide`;
  unsupported fields return empty).
- **Coverage gaps are per-product and can be total**: one product on 1 of ~50 hosts that Discover
  and process telemetry show running it; another had zero findings tenant-wide, including on the
  server running 16 of its services, while that host returned 96 findings for two other vendors.
  Never scope a software estate with Spotlight, and never accept "no Spotlight CVE" as evidence
  for a non-Microsoft product, including as a ticket acceptance criterion.
- `host_info.hostname` is rejected, HTTP 400 `property "host_info.hostname" not allowed`; scope
  by `aid` (resolve via `falcon_search_hosts`).
- `status:'reopen'` is a remediated finding re-detected (regressed or incomplete patch):
  root-cause it. Facet `['cve','host_info']` for scoring plus asset context in one call.

## Real Time Response (read-only tier)

- `falcon_run_rtr_read_only_command_and_wait` needs a `session_id`; `device_id` alone fails with
  `1 validation error for run_read_only_command_and_waitArguments / session_id / Field required`.
  `falcon_init_rtr_session` first (it returns the host's command schema and `offline_queued: false`
  when live), carry `session_id` into every command, `falcon_delete_rtr_session` when done.
- **`rtr_state: enabled` is policy, not liveness**: init against a host not checked in returns
  HTTP 404, `errors[0].code` `40401`, `Could not establish sensor comms`. Compare `last_seen` to
  now before planning RTR; laptops are unreachable off-hours.
- Read-only cannot read a PE version property (needs the `runscript` tier). Use `filehash` mapped
  via the software inventory, or `reg query` an app's version value, and expect a vendor key to
  hold none (`HKLM\SOFTWARE\Veeam\Veeam Backup and Replication` held only `TempPathDir` and
  provider GUIDs).

## Console deep-links and writes

- Use the detection's `falcon_host_link` verbatim. A hand-built
  `…/unified-detections/?filter=…&info=<id>` renders an unfiltered page, and the path varies by
  `product`: `/unified-detections/<composite_id>?_cid=<code>` (`thirdparty`),
  `/activity-v2/detections/<composite_id>?_cid=<code>` (`epp`),
  `/automated-leads/<composite_id>?_cid=<code>` (automated-lead). Templating one shape across
  another yields a dead link that looks right.
- Only detections carry a link: `falcon_search_hosts` has no URL field; on
  `falcon_search_vulnerabilities`, `remediation.entities[].link` is an empty string and
  `remediation.entities[].vendor_url` / `cve.vendor_advisory[]` are external vendor URLs.
- `falcon_update_detections` batches many `ids`. The top-level `comment` rollup comes back
  word-scrambled: read `comments[]` (`falcon_user_id`, `timestamp`, `value`). Comments post as
  the API client, so name the human in the text. Resolution is tag-based: `true_positive` /
  `false_positive` / `ignored` populate the console column; `status:closed` alone does not.

## Correlation edges for common sources (M365, mail gateways, Zscaler ZIA)

Worked examples; they apply only where your estate ingests the same sources.

- **M365 / Exchange audit**: Defender-passthrough detections carry no target mailbox or
  operation, so the NG-SIEM pivot into M365 audit rows is mandatory. Admin actor UPNs use
  `<tenant>.onmicrosoft.com` (a primary-domain filter misses them). Subjects nest at
  `Vendor.Folders[N].FolderItems[M].Subject`.
- **Mail-flow rows inflate; dedupe before counting.** One message yields a Message Trace
  `Delivered` per recipient leg, a journaling/archiving fork, each gateway stage (receipt, spam,
  process, delivery), and a `MailItemsAccessed` per open; `Status: Expanded` is DL fan-out, not
  delivery. **Message-ID is not a safe dedupe key** (this corrects earlier advice to dedupe on
  Message-ID + recipient): journal forks carry different synthetic Message-IDs and
  `aggregateId`s. The journal fork shows three co-occurring markers: a Message-ID ending
  `@journal.report.generator`, a recipient at the archiver's ingest domain, and `senderEnvelope`
  equal to the journaling address. Dedupe on sender header + subject + attachment hash.
- **A journaled message's alert names the envelope, not the author**: `falcon_get_detection_details`
  gives `sender` = the SMTP envelope and `message_id` = the synthetic `…@journal.report.generator`
  id. The discriminating field, `senderHeader`, is absent from the alert and lives only in the
  NG-SIEM row's `@rawstring`; reading direction off the alert alone turns an inbound phish into
  an outbound lure from your own user.
- **A gateway hold emits a delivery row for the hold notice** under the same `aggregateId`: an
  `emailsecurity.process` action `Hld`, then an `emailsecurity.delivery` row that is the
  postmaster notification (postmaster sender, "suspicious files" subject, `emailSize: 0`,
  `numberAttachments: 0`; check `Vendor.recipients` / `Vendor.subject`), not proof of delivery.
- **Message Trace may cover only some accepted domains**: `#event.dataset=messagetrace.event`
  returned zero for one domain across ~80,000 events in 1.5 days (a true negative per the
  counters). `groupBy` the recipient domain first and state which domains an absence claim covers.
- Tenant boundary: only legs touching your tenant are visible. `MailItemsAccessed` proves a
  client fetched, not a human read; `MailAccessType` `Bind` (explicit open) vs `Sync`
  (background) disambiguates.
- **Zscaler ZIA to sensor**: `zia.web` `source.Id` / `client.Id` *is* the Falcon `aid` (exact
  join). On tunnel-client hosts, endpoint DNS/NetworkConnect attributes egress to `ZSATunnel.exe`,
  not the browser; naming the originating process definitively needs live RTR. A decrypting proxy
  double-logs: a CONNECT to `host:443` with the tunnel UA, then the decrypted request with
  `useragent="Unknown"`; filter the CONNECT leg (`url=/:443$/`) for one row per session.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
