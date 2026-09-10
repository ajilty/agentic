---
name: working-with-splunk-mcp
description: "Splunk MCP gotchas: \"Request failed: Session is not logged in.\" is session expiry not a bad query (known splunklib bug) and only one splunk_run_query lands per re-prime, so never batch them; the saia_* assistant tools can return \"Session terminated\" and stay dead; a broken automatic CIM lookup (\"Could not load lookup=LOOKUP-<name>\") aborts a raw search and any CIM-aliased field reference regardless of app context, with tstats and rex on _raw as the fallbacks and what each costs; a JSON sourcetype extracted twice makes every field a 2-value multivalue so stats count inflates; an absolute earliest_time in Splunk own %m/%d/%Y:%H:%M:%S form is rejected as \"Invalid earliest_time\"; multivalue fields drop silently from table; _time renders in the search head timezone; splunk_get_indexes size/count fields are stubs; numbers come back as strings. Use when a splunk_run_query fails mid-session, a search aborts on a lookup error, a count looks doubled, picking an index, or before firing multiple searches at once."
---

# Working with the Splunk MCP — sharp edges

Operating mechanics for the Splunk (Cloud) MCP tools (`splunk_run_query`, `splunk_get_*`, the
`saia_*` assistant tools). These are `splunklib` (splunk-sdk-python) behaviors, true of any
Splunk MCP surface, not one server.

## Auth / session

- **`Request failed: Session is not logged in.` is session expiry, not a bad query or a
  permission problem.** The identical query succeeds once the session is live. It is a known
  upstream `splunklib` session-key bug — auto-relogin "succeeds, but there was an auth error on
  the next request" (`splunk-sdk-python` #486), persisting across SDK versions. The real fix is
  server-side (token/JWT auth, or upgrading the connector), so do **not** try to fix it from the
  query side.
- **Re-prime, then send exactly one search.** A `splunk_get_*` metadata call (`splunk_get_info`,
  `splunk_get_user_info`) re-establishes the session. Follow it with the search.
- **Only one `splunk_run_query` reliably lands per re-prime, and it degrades over a long
  session** — later re-primes stop holding.
- **Never batch multiple `splunk_run_query` calls in one message.** They serialize through a
  single session and every call after the first fails with the session error. Issue them one per
  turn.
- On the error, re-run a `get_*` call and resend a single search — don't blind-retry the same
  query as if it were malformed.
- **The `saia_*` assistant tools can go dead for a whole session.** `saia_find_data_source`
  returned `Session terminated` and never recovered, while `splunk_run_query` and the `get_*`
  tools worked normally throughout. The substitute is `splunk_get_indexes` plus a
  `| stats count by sourcetype` probe — don't spend the session trying to revive the assistant.

## A broken automatic CIM lookup aborts searches that never mention it

- **`Could not load lookup=LOOKUP-<name>` is a broken automatic lookup on the sourcetype, not a
  bad query.** Observed as `[idx-…,sh-…] Could not load lookup=LOOKUP-dns_action_lookup` on a
  raw `search` over several unrelated indexes, **regardless of whether `app` is set to
  `search`** — so switching app context is not the fix.
- **It also fires on any reference to a CIM-*aliased* field**, even in an index the raw search
  handles fine: naming the aliased field in `stats`, `rename` or `spath` aborted the search,
  while sibling non-aliased fields in the same events were unaffected.
- **Two fallbacks, and both cost you something.**
  - `| tstats count where index=<i> by index` over the same indexes works and returns data —
    but you lose free-text matching, and `TERM()` only matches on tokenizer boundaries, so a
    null result from tstats is **weak** evidence. Label it as such rather than reporting a clean
    negative.
  - Extracting the same values with `rex` on `_raw` works where the aliased field name does not.

## Choosing an index

- **`splunk_get_indexes` size/count fields are stubbed.** It returns `currentDBSizeMB: "1"` and
  `totalEventCount: "0"` for *every* index regardless of real contents, and caps the list
  (`truncated: true`, with the real count in `total_rows`). You cannot use these fields to find
  which index holds data — they are placeholders.
- Pick candidate indexes by name / domain knowledge, then confirm by searching:
  `... | stats count by index`. Empty output means wrong index or wrong window, not "no such
  data."

## Result shapes

- **A JSON sourcetype can be extracted twice, so every field comes back as a 2-value
  multivalue of identical values and `stats count` inflates silently.** Confirm the shape
  first: a single event whose every field renders as two identical values is the tell. Counts
  built on it are not merely doubled — an event-count run over the sourcetype came back at
  19,962 and then 4,058 against a `| tstats count where index=<i>` truth of 3,313 for the whole
  sourcetype, so treat any raw-event count here as unreliable rather than as a fixed multiple.
  **`dedup <id>` does NOT fix it.** Use `dc(<unique_id_field>)`, or `mvindex(FIELD, 0)` — and
  check whether the estate's own detection SPL already does one of these, then match it.
- **A multivalue field silently drops out of `table`.** A bare `table target{}.alternateId` on a
  sourcetype where that field is an array returns nothing for the column, with no error. Use
  `mvjoin('target{}.alternateId', "|")`.
- **The search head renders `_time` in its own timezone while raw JSON timestamps are UTC**, so
  `strftime` output is already local. Cross-check one row's `_raw` timestamp against its `_time`
  before trusting any rendered time.
- **An absolute `earliest_time` in Splunk's own `%m/%d/%Y:%H:%M:%S` form is rejected** —
  `HTTP 400 'Invalid earliest_time'`. Relative windows (`-60h`) work.

- **Numbers come back as strings** (`"count": "28"`). Cast before doing math or comparisons.
- **A raw-event `| table ...` dump overflows the response cap and spills to a
  `tool-results/*.txt` file** — the tool hands you the path, not the rows. Aggregate in-query
  (`stats`/`chart`/`top` on the few fields you need) instead of tabling wide raw events; `grep`
  the spill file when you must parse one.
- **`| rest /servicesNS/-/-/saved/searches count=0` works through `splunk_run_query`** and is
  the only way to read a saved detection's SPL, cron schedule and threshold. The `search` field
  is long enough that the tool truncates it — slice it with `substr` across successive calls.
- **`index=_internal sourcetype=scheduler savedsearch_name="<title>"`** with `status`,
  `result_count` and `alert_actions` answers "has this alert been firing, and will it fire
  again" without touching the detection itself.
- **A substring match on a bare token is a false-positive trap.** A search term like `8041`
  matches that string anywhere in an event (an ephemeral port, a byte count), not just the field
  you meant. Anchor to the field (`dest_port=8041`) or a distinctive multi-character IOC, and
  sanity-check the time span before concluding a hit is real.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
