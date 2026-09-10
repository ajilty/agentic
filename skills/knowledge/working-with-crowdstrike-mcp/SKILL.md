---
name: working-with-crowdstrike-mcp
description: "CrowdStrike Falcon MCP (falcon_* tools: falcon_search_ngsiem, falcon_search_detections, falcon_aggregate_detections, falcon_get_detection_details, falcon_update_detections, falcon_search_applications, falcon_search_managed_assets, falcon_search_vulnerabilities, falcon_search_hosts, falcon_search_report_executions, falcon_init_rtr_session, falcon_run_rtr_read_only_command_and_wait). Use before writing CQL or FQL, when a result is empty, truncated, mis-counted, or spilled to tool-results/*.txt, before any 'version installed / still installed' claim, when falcon_search_vulnerabilities returns zero for a product, and on: job.processed_events 0, groupBy(limit) vs top(), job.parsed_query, repository param vs #repo tag, ProcessBlocked, AsepValueUpdate, FileVersion missing, severity_name absent on automated-lead rows, is_closed true with status new, cmdline wildcard, sum_other_doc_count 0 with a facet shortfall, pagination after cursor re-serving page 1, host.id vs device id, `invalid filter; operator in not allowed for property id`, `property host_info.hostname not allowed`, `session_id / Field required`, 40401 `Could not establish sensor comms`, rtr_state enabled, falcon_host_link, @journal.report.generator, senderHeader, zia.web, ZSATunnel.exe."
---

# Working with the CrowdStrike Falcon MCP — sharp edges

Operating the tool. Vendor field meanings appear only where a correlation edge turns on them
(last section); keep the rest in your own per-source notes.

## falcon_search_ngsiem (CQL / LogScale)

- **Sample before you aggregate**: `<filter> | head(3)`, read the real field names, then
  `top()`/`count()`. `top(missing_field)` returns empty with no error.
- **`repository`** scopes and speeds the search: `search-all` (default, slowest), `third-party`
  (connector feeds), `investigate_view` (endpoint), `falcon_for_it_view`, `forensics_view`. **It
  is a different namespace from the `#repo` tag**: `#repo=third-party` with
  `repository: 'third-party'` returned 0 rows and 0 `processed_events`; the data resolved under
  `repository: 'search-all'` with the vendor's own `#repo=<vendor>`. Read `#repo` off `head(3)`
  before pinning either.
- **`groupBy(field, limit=N)` keeps the lexicographically-first N groups, not the top N by
  count**, and a trailing `sort()` ranks only that subset:
  `groupBy(user.name, limit=25) | sort(_count, order=desc)` silently drops the true maximum. Use
  `top(field, limit=N)` for "most"; use `groupBy(…limit…)` only with the limit above
  cardinality.
- `OR` across two `regex()` calls is HTTP 400; write `field=/.../i or field=/.../i`.

### Reading results

- Numbers are strings (`"_count": "2773932"`): cast before math. Spilled results carry no
  `total`; re-run with an in-query `count()` if it matters.
- **Zero rows with `job.processed_events: 0` is not a negative**: nothing was scanned; a real
  negative has `processed_events > 0`. The tool flags this by appending a hint plus the whole
  inline CQL guide, which is easy to skim past. Read `processed_events` before reporting
  "nothing found".
- **A short free-text token is not a filter.** A two-character token into `groupBy` scanned
  215,686,423 events and returned lexicographically-first groups unrelated to the token (192
  groups where 128 mentioned it); a distinctive phrase was precise. Compare `job.event_count`
  against `job.processed_events` before trusting any free-text aggregation, and anchor to fields
  (`Vendor.actor.alternateId=/x/i`) or tags: `#repo`, `#Vendor`, `#type`, `#event.dataset`,
  `#event.module`, `#event.kind`.
- **`job.parsed_query` omits trailing `groupBy`/`sort` stages that demonstrably ran**; confirm
  aggregation from the result shape.
- **Spills**: a wide `head(N)` spills to `tool-results/*.txt`; aggregate in-query.
  `falcon_search_applications` `name:'*Product*'` over a widely-installed product also spills.
  Calibration: `falcon_search_detections` `product:'automated-lead'`, `limit: 50` returned 16
  records and still spilled (100,500 chars); lowering `limit` will not save you, plan to parse
  (`python3 json.load`). For raw evidence, `… | select([@timestamp, @rawstring])`: a free-text
  search plus `head(20)` on mail-gateway rows spilled at 74,725 chars; `select()` returned the
  same at a fraction.

### Endpoint telemetry fields

- **A blocked process lands under `#event_simpleName=ProcessBlocked`** (full `CommandLine`,
  `ImageFileName`, `ParentBaseFileName`), not `ProcessRollup2`: zero `ProcessRollup2` children of
  a parent is not "no telemetry" when the detection shows prevention.
- `groupBy` silently drops a column whose field is absent on the rows. `ProcessRollup2` does not
  reliably populate `FileVersion`: pin a build by `SHA256HashData` mapped via
  `falcon_search_applications` or RTR `filehash` (read-only RTR has no PE-version command;
  `reg query` is the other route, and a vendor key may hold no version value). `AsepValueUpdate`
  (`investigate_view`) has no `ImageFileName`; its writer is `ContextProcessId`, which equals the
  detection's `process_id` exactly: the alert-to-registry join.

## search_* / aggregate_* FQL tools (detections, hosts, incidents, cases, ...)

- FQL, not CQL (`falcon://<domain>/.../fql-guide`). Unknown fields split: some are HTTP 400 (bare
  `cve:'…'`, write `cve.id:'…'`; `host_info.hostname`), others return empty silently (`cmdline`),
  so an empty set never proves the filter was evaluated.
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
- **`falcon_search_detections` `q` is a fuzzy multi-token OR match.** Single-token `q` is usable
  (positive control: 225 rows); multi-token returns unrelated rows. Prefer `sha256:`,
  `device.hostname:`, `pattern_id:`; validate any empty `q` against a positive control before
  reporting a negative.
- **`falcon_search_report_executions` cannot say whether a report was read** (Falcon exposes no
  read/download state; the delivery notification only proves generation) and is a token trap:
  `status:'DONE'`, `limit: 15` spilled 153,800 chars / 1,207 lines of XDR correlation-rule
  execution metadata. Filter by report id or skip it.

## falcon_search_applications (Discover)

Discover is the authoritative *ever-installed* inventory: use it (not Spotlight, not process
telemetry) for "where is X installed", within these limits.

- **The `after` cursor re-serves page 1** (passing `pagination.next` back as `after`), so a
  paging loop caps at one page and looks complete.
  Union two opposite sorts (`name.asc` then `name.desc`, or on `last_updated_timestamp`) and
  dedupe on `id`; that covers up to 2x page size, and `pagination.total` is still true.
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
- `id` rejects list syntax (`id:[...]`) with a hard error,
  `invalid filter; operator in not allowed for property id`; use comma-OR equality,
  `id:'<a>',id:'<b>'`, several per call.

## falcon_search_vulnerabilities (Spotlight)

- No product/vendor/app filter field; reach a product only by enumerating CVEs:
  `cve.id:'CVE-…',cve.id:'CVE-…'` (guide: `falcon://spotlight/vulnerabilities/fql-guide`).
- **Coverage is per-product and can be total**: one product reported on 1 of ~50 hosts running
  it; another had zero findings tenant-wide including on a server running 16 of its services that
  returned 96 findings for other vendors. Never scope an estate with Spotlight or accept "no
  Spotlight CVE" as evidence for a non-Microsoft product.
- `host_info.hostname` is rejected, HTTP 400 `property "host_info.hostname" not allowed`; scope
  by `aid` (resolve via `falcon_search_hosts`).

## Real Time Response (read-only tier)

- `falcon_run_rtr_read_only_command_and_wait` needs a `session_id`; `device_id` alone fails with
  `1 validation error for run_read_only_command_and_waitArguments / session_id / Field required`.
  `falcon_init_rtr_session` first (it returns the host's command schema and `offline_queued: false`
  when live), carry `session_id` into every command, `falcon_delete_rtr_session` when done.
- **`rtr_state: enabled` is policy, not liveness**: init against a host not checked in returns
  HTTP 404, `errors[0].code` `40401`, `Could not establish sensor comms`. Compare `last_seen` to
  now before planning RTR; laptops are unreachable off-hours.

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
  operation; the NG-SIEM pivot into M365 audit rows is mandatory.
- **A journaled message's alert names the envelope, not the author**: `falcon_get_detection_details`
  gives `sender` = the SMTP envelope and `message_id` = the synthetic `…@journal.report.generator`
  id. The discriminating field, `senderHeader`, is absent from the alert and lives only in the
  NG-SIEM row's `@rawstring`; reading direction off the alert alone turns an inbound phish into
  an outbound lure from your own user.
- **Zscaler ZIA to sensor**: `zia.web` `source.Id` / `client.Id` *is* the Falcon `aid` (exact
  join). On tunnel-client hosts, endpoint DNS/NetworkConnect attributes egress to `ZSATunnel.exe`,
  not the browser; naming the originating process needs live RTR.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
