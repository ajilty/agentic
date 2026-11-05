---
name: working-with-crowdstrike-mcp
description: "CrowdStrike Falcon MCP (any falcon_* tool: NGSIEM/CQL search, detections and hosts FQL, Discover applications, Spotlight vulnerabilities, RTR). Load before the first Falcon call in a session and before writing any CQL or FQL; covers query syntax traps, empty or truncated results, and version-installed claims."
---

# Working with the CrowdStrike Falcon MCP — sharp edges

Unless a bullet quotes an error, every failure below comes back as clean output: zero rows,
dropped columns or records, wrong counts, truncated lists.

## falcon_search_ngsiem (CQL / LogScale)

- **The CQL argument is `query_string`, not `query`**: `query` fails as `Field required` for
  `query_string`, which reads like a missing query. `start`/`end` are ISO-8601 only
  (`Invalid isoformat string: '7d'`).
- **A `field := formatTime(...)` assignment stage drops every later `select()` / `head()`.**
  Format last.
- **Sample before you aggregate**: `<filter> | head(3)`, read the real field names, then
  `top()`/`count()`. `top(missing_field)` returns empty, and so does a real field still inside
  `@rawstring` on an unparsed dataset (`groupBy` returned 0 rows against 136 with the grouping
  removed; the tool's hint called the negative genuine). `processed_events` is positive either
  way (three such queries), so validate a negative on the filter alone (`<filter> | head(3)` or
  `| count()`).
- **`repository` is a different namespace from the `#repo` tag.** Values: `search-all`
  (default, slowest), `third-party`, `investigate_view`, `falcon_for_it_view`,
  `forensics_view`. `#repo=third-party` with `repository: 'third-party'`
  returned 0 rows and 0 `processed_events`; the data resolved under `repository: 'search-all'`
  with the vendor's own `#repo=<vendor>`. Read `#repo` off `head(3)` before pinning either.
- **A `#repo` can lack an entire source organisation while carrying others.** A week over one
  `#repo` scanned 279,375 events and matched none for a principal the authoritative source held
  86 events for in the same window; the `#repo` carried that principal's events from another
  org of the vendor. Confirm the org is onboarded first: `#repo=<repo> | top(<org field>)`.
- **`groupBy(field, limit=N)` keeps the lexicographically-first N groups, not the top N by
  count**, and a trailing `sort()` ranks only that subset: `groupBy(user.name, limit=25) |
  sort(_count, order=desc)` drops the true maximum. Use `top(field, limit=N)` for "most";
  `groupBy(…limit…)` only with the limit above cardinality.
- `OR` across two `regex()` calls is HTTP 400; write `field=/.../i or field=/.../i`.
- **`table(limit=N)` truncates from the END of the query window**: raising the limit never
  surfaces an early event; narrow the time range.
- **A `groupBy` after a loose regex filter (`CommandLine=/pattern/i`) can return implausible
  fleet-wide counts.** Count on an exact-match filter plus an explicit `case {}` control; keep
  the loose regex for discovery.

### Reading results

- Spilled results carry no `total`; re-run with an in-query `count()` if it matters.
- **Zero rows with `job.processed_events: 0` is not a negative**: nothing was scanned. A real
  negative needs `processed_events > 0`, and after `top()`/`groupBy()` even that is not enough
  (above). The zero-scan hint (the whole CQL guide appended) is easy to skim past.
- **A short free-text token is not a filter.** A two-character token into `groupBy` scanned
  215,686,423 events and returned lexicographically-first groups unrelated to it (192 groups
  where 128 mentioned it). A distinctive phrase is precise and cheap over `search-all` (six
  months, ~18TB, ~100s): `groupBy([#repo, #event.dataset])`, then drill the repos that hit.
  Compare `job.event_count` to `job.processed_events` before trusting a free-text aggregation;
  anchor to fields (`Vendor.actor.alternateId=/x/i`) or tags: `#repo`, `#Vendor`, `#type`,
  `#event.dataset`, `#event.module`, `#event.kind`.
- **`job.parsed_query` omits trailing `groupBy`/`sort` stages that ran**; confirm aggregation
  from the result shape.
- **`select()` drops columns, not `@rawstring` weight; aggregate in-query.**
  `select([@timestamp, @rawstring])` cut a mail-gateway `head(20)` from 74,725 chars to a
  fraction, but two user-activity audit rows were 156K and one Entra sign-in ~25K (`head(2)`
  spills): `groupBy` named fields, or `regex("(?<name>...)", field=@rawstring)`.

### Endpoint telemetry fields

- **A blocked process lands under `#event_simpleName=ProcessBlocked`** (full `CommandLine`,
  `ImageFileName`, `ParentBaseFileName`), not `ProcessRollup2`: zero `ProcessRollup2` children
  is not "no telemetry" when the detection shows prevention.
- **For "what is listening / what connected inbound", use `NetworkReceiveAcceptIP4`, not
  `NetworkListenIP4`**: `#event_simpleName=NetworkListenIP4` returned zero rows for a provably
  listening port. A wildcard-bound socket (`:::<port>`) also needs `NetworkReceiveAcceptIP6`,
  or the IPv6 half is missed.
- `groupBy` drops a column whose field is absent on the rows. `ProcessRollup2` does not
  reliably populate `FileVersion`: pin a build by `SHA256HashData` via
  `falcon_search_applications` or RTR `filehash` (read-only RTR has no PE-version command;
  `reg query` is the other route, and a vendor key may hold no version value).
- **Detection process ids join to sensor events** (`repository: 'investigate_view'`,
  `aid=<aid>`): an automated lead's `threatgraph_indicators[].process_id` is
  `TargetProcessId` on `ProcessRollup2` (3 of 3 resolved):
  `aid=<aid> #event_simpleName=ProcessRollup2 TargetProcessId=/^(<pid1>|<pid2>|<pid3>)$/ |
  select([@timestamp, TargetProcessId, ParentProcessId, UserName, FileName, CommandLine,
  ParentBaseFileName, SHA256HashData])`. `AsepValueUpdate` has no `ImageFileName`; its writer
  is `ContextProcessId`, equal to the detection's `process_id`. Check a false
  positive by fleet prevalence: `SHA256HashData=<hash> | count(aid, distinct=true)`.

## FQL tools (search_* / aggregate_*: detections, hosts, cases, ...)

- FQL, not CQL (`falcon://<domain>/.../fql-guide`). Unknown fields split: some are HTTP 400
  (bare `cve:'…'`, write `cve.id:'…'`; `host_info.hostname`, see Spotlight), others return
  empty (`cmdline`: `cmdline:'*substring*'` on `falcon_search_detections` /
  `falcon_aggregate_detections`), so an empty set never proves the filter was evaluated. Pivot
  to `pattern_id:`, `technique_id:`, `tags:`, or a time-boxed `created_timestamp:`.
- **Neither a severity filter nor an open-items filter is a safe default on the endpoint
  detection queue**; each alone zeroes it. (1) A tenant emitting no `product: epp` alerts
  carries endpoint signal as `automated-lead` / `automated-lead-context` rows with a numeric
  `score` and no `severity_name`, so `severity:>70`, `severity_name:'high'` and a
  `severity.desc` sort drop the whole queue. (2) `is_closed` can be a schema artifact: every
  automated lead (16 of 16) reported `status: 'new'` with `is_closed: true`,
  `seconds_to_resolved: 0`, `show_in_ui: true`, so `is_closed:false` also returns zero.
  First facet `falcon_aggregate_detections` on `product` and `source_vendors`; triage on
  `product` + `created_timestamp`.
- **`falcon_aggregate_detections` drops records lacking the faceted field**: a `severity_name`
  facet summed to 237 against `pagination.total` 253 with `sum_other_doc_count` 0. Pass
  `missing` to bucket them; cross-check facet sum against `pagination.total` every time.
- **`falcon_search_detections` `q` is a fuzzy multi-token OR match.** Single-token `q` works
  (positive control: 225 rows); multi-token returns unrelated rows. Prefer `sha256:`,
  `device.hostname:`, `pattern_id:`; check an empty `q` against a positive control.
- **Spills** (`tool-results/*.txt`), weight per record: host ~6-7.5K chars
  (`falcon_search_hosts` `limit: 500` returned 74 hosts, 453K; `limit: 1` still returns
  `pagination.total`: count from that); `falcon_get_detection_details` ~15-30K per id (count
  via `falcon_aggregate_detections`); `falcon_search_detections` `product:'automated-lead'`,
  `limit: 50`: 16 records, 100,500 chars, 2,156 lines; `falcon_search_applications`
  `name:'*Product*'` on a widely-installed product.
- **`falcon_search_report_executions` cannot say whether a report was read** (no read/download
  state; the delivery notification only proves generation) and is a token trap:
  `status:'DONE'`, `limit: 15` spilled 153,800 chars / 1,207 lines. Filter by report id or skip
  it.
- **`falcon_idp_investigate_entity` can be scope-denied where every other tool works**:
  `access denied, scope not permitted Required scopes: Identity Protection Entities:read` (a
  separately licensed module, not connectivity). `entity_names` and `email_addresses` each take
  a string, one entity per call; a list is rejected as if the entity were bad:
  `1 validation error for investigate_entityArguments | entity_names | Input should be a valid
  string [type=string_type, input_value=['<name>'], input_type=list]`.

## falcon_search_applications (Discover)

Discover, not Spotlight or process telemetry, answers "where is X installed" (an
*ever-installed* inventory), within these limits.

- **The `after` cursor re-serves page 1** (passing `pagination.next` back as `after`), so a
  paging loop caps at one page and looks complete. Union two opposite sorts (`name.asc` then
  `name.desc`, or on `last_updated_timestamp`) and dedupe on `id`: up to 2x page size, and
  `pagination.total` is still true.
- **Component roll-up over-counts ~52x**: every Veeam component (Agent, console, Mount Service,
  Transport) reports `name: "Veeam Backup & Replication"`; 263 distinct hosts where 5 ran the
  server role. Filter `host.product_type_desc`, read component-level names, and diff Discover
  against running-process telemetry: the disagreement is the finding.
- **No row is ever retired** (no removal event, no last-seen decay): one host listed three
  major versions long after two were uninstalled, so a patched host looks unpatched. Treat the
  oldest version as a flag to check on-host (RTR `filehash`, process telemetry); never open or
  close a remediation ticket on Discover alone.

## falcon_search_managed_assets (application row to host)

- An application row's `host.id` is an opaque asset id, not the 32-hex device id; a
  host-scoped call returns empty. Join via `id:'<cid>_<assetid>'`. `id:[...]` is a hard error,
  `invalid filter; operator in not allowed for property id`; use comma-OR equality,
  `id:'<a>',id:'<b>'`, several per call.

## falcon_search_vulnerabilities (Spotlight)

- No product/vendor/app filter field; enumerate CVEs: `cve.id:'CVE-…',cve.id:'CVE-…'` (guide:
  `falcon://spotlight/vulnerabilities/fql-guide`).
- **Coverage is per-product and can be total**: one product reported on 1 of ~50 hosts running
  it; another had zero findings tenant-wide, including on a server running 16 of its services
  that returned 96 findings for other vendors. Never scope an estate with Spotlight or accept
  "no Spotlight CVE" as evidence for a non-Microsoft product.
- `host_info.hostname` is HTTP 400 `property "host_info.hostname" not allowed`; scope by `aid`
  (resolve via `falcon_search_hosts`, where `hostname:'*x*'` is HTTP 400 but `hostname:~'x'`
  works).
- **Exploit status is exposed, behind `facet: "cve"`.** Without it the cve block carries only
  the id; with it each finding carries its ExPRT rating, exploit status and CISA KEV flag. Rank
  on those, not on finding count.

## Firewall Management (NG-SIEM `FirewallMatchEvent` + rule-group writes)

- **`FirewallMatchEvent` returns zero rows and zero `processed_events` tenant-wide when
  Firewall Management has never enforced on the estate**, with a hint that reads like a syntax
  complaint. Confirm enforcement before reading the zero as "no blocked traffic."
- A fleet-wide `groupBy` on a `RemotePort` hits the same `limit=` truncation (empty
  `warnings`) and is dominated by Zscaler tunnel noise: pin the destination address, not the
  port.
- **The MCP can create/delete rule groups but not attach one to a policy**: a group from
  `falcon_create_firewall_rule_group` sits `enabled: false` with `policy_ids` empty until
  wired up in the console.

## Real Time Response (read-only tier)

- `falcon_run_rtr_read_only_command_and_wait` and `falcon_execute_rtr_read_only_command` need a
  `session_id`; a `device_id` alone fails with
  `1 validation error for run_read_only_command_and_waitArguments / session_id / Field required`.
  `falcon_init_rtr_session` first (`offline_queued: false` means live), carry `session_id`
  into every command, `falcon_delete_rtr_session` when done.
- **A session can expire mid-use and reads as a missing one**:
  `Could not find existing session` (code `40002`). Re-init and resume.
- **`rtr_state: enabled` is policy, not liveness**: init against a host not checked in returns
  HTTP 404, `errors[0].code` `40401`, `Could not establish sensor comms`. Compare `last_seen` to
  now before planning RTR.

## Console deep-links and writes

- Use the detection's `falcon_host_link` verbatim. A hand-built
  `…/unified-detections/?filter=…&info=<id>` renders an unfiltered page, and the path varies by
  `product`: `/unified-detections/<composite_id>?_cid=<code>` (`thirdparty`),
  `/activity-v2/detections/<composite_id>?_cid=<code>` (`epp`),
  `/automated-leads/<composite_id>?_cid=<code>` (automated-lead). Templating one shape across
  another yields a dead link that looks right.
- Only detections carry a link: `falcon_search_hosts` has no URL field; on
  `falcon_search_vulnerabilities`, `remediation.entities[].link` is empty and
  `remediation.entities[].vendor_url` / `cve.vendor_advisory[]` are vendor URLs.
- `falcon_update_detections` returns empty on success and batches many `ids`; confirm by
  filtered re-read (status, tags, `comments[]`). The top-level `comment` rollup comes back
  word-scrambled: read `comments[]` (`falcon_user_id`, `timestamp`, `value`). Comments post as
  the API client, so name the human in the text. Resolution is tag-based: `true_positive` /
  `false_positive` / `ignored` populate the console column; `status:closed` alone does not.

## Correlating sources (M365, mail gateways, Zscaler ZIA)

- **M365 / Exchange audit**: Defender-passthrough detections carry no target mailbox or
  operation; pivot into the NG-SIEM M365 audit rows.
- **An alert's `sender` is not the author.** On a journaled message
  `falcon_get_detection_details` gives `sender` = the SMTP envelope and `message_id` = the
  synthetic `…@journal.report.generator` id; the discriminating `senderHeader` lives only in the
  NG-SIEM row's `@rawstring`, and reading direction off the alert turns an inbound phish into an
  outbound lure from your own user. Spearphish detections can carry an empty `sender` with
  `header_from` populated (all 24 rows of one campaign): key a sweep on `header_from` too.
- **Mail-gateway process rows (Mimecast `emailsecurity.process`) carry `Vendor.attachments`
  and `email.subject` but no sender or recipient**: a sender + attachment filter returns zero
  with `processed_events: 0`. Join through subject or messageId / `aggregateId`.
  `Vendor.route` is on dlp/spam rows, not receipt rows (so it drops from `groupBy`); classify
  receipt direction by recipient-domain regex.
- **Message-ID is not a dedupe key across journal legs**: two forks of one message carry
  different synthetic Message-IDs and `aggregateId`s. A fork shows three markers together
  (Message-ID ending `@journal.report.generator`, a recipient at the archiver's ingest domain,
  `senderEnvelope` equal to the journaling address); dedupe on sender header + subject +
  attachment hash.
- **Zscaler ZIA to sensor**: `zia.web` `source.Id` / `client.Id` *is* the Falcon `aid` (exact
  join). On tunnel-client hosts, endpoint DNS/NetworkConnect attributes egress to
  `ZSATunnel.exe`, not the browser; naming the originating process needs live RTR.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
