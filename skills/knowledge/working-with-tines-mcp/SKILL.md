---
name: working-with-tines-mcp
description: "Tines MCP cases (read_case, search_cases, case and record tools). Load before the first Tines case call in a session; covers case-read payload size and record-heavy reads. Also when asked to summarize, triage or pull the notes of a Tines case."
---

# Working with the Tines MCP (cases) — sharp edges

Reading cases without blowing the response cap.

## read_case

- **`case: [{}]` also embeds every linked record** (the tool description promises only
  metadata, block index and closure conditions): `records` was ~98% of the payload, 20K to
  1.6M characters, failing `Error: result (<n> characters) exceeds maximum allowed tokens`.
  Omit `case` unless you need closure conditions; each of these returned 2-15K:
  `case_field: [{}]`, `activity: [{"category": "notes", "limit": 5}]`,
  `block: [{"block_id": "<id>"}]`, `record: [{}]`.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
