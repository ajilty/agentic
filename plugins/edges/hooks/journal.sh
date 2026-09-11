#!/usr/bin/env bash
# PostToolUseFailure (any tool) and PostToolUse (mcp__.*): append one scrubbed row per
# tool failure to the local edges journal, so a later `/edges:harvest` can read what this
# session hit without anyone having to remember it.
#
# Input: hook payload JSON on STDIN. PostToolUseFailure carries the error in `.error`;
# an MCP tool that failed inside a successful call carries `isError: true` (or
# `is_error`) on `.tool_response`, with the text in its content. Anything else is
# ignored. Capture only, no judgment: the row is a pointer plus a scrubbed string.
#
# Journal: ${EDGES_JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/edges/journal.jsonl},
# append-only JSONL. Never inside a repo (it is work observation, not code), user-level
# not per-project (the same tool fails the same way in every repo; the `project` field
# lets harvest filter). Rows carry session_id, transcript_path and tool_use_id so the
# exact call, and the retries after it, are one grep away while the transcript lives.
#
# The write applies a mechanical scrub only: emails, URLs, IPv4, UUIDs, long digit runs,
# and home paths become placeholders. Rows still carry identities: people's names, org
# names, ticket keys, product names — and error text is otherwise verbatim, capped at 400
# chars. Redaction of identities is the harvester's job at contribution time; this journal
# is a local raw store, not a redacted one.
#
# Contract: always exit 0, never print. This runs async and a broken journal must never
# cost the session anything. Fail-open on missing jq.

set -u
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

journal="${EDGES_JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/edges/journal.jsonl}"

row=$(printf '%s' "$payload" | jq -c --arg home "$HOME" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  def text_of(r):
    if (r|type) == "string" then r
    elif (r|type) == "object" then
      (r.content // [] | if type == "array" then map(.text? // empty) | join(" ") else tostring end)
      | if . == "" then (r|tostring) else . end
    else (r|tostring) end;
  def redact:
    gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "<email>")
    | gsub("https?://[^\\s\"\\u0027\\)>]+"; "<url>")
    | gsub("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"; "<ip>")
    | gsub("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b"; "<uuid>")
    | gsub("\\b[0-9]{6,}\\b"; "<n>")
    | gsub($home; "~");
  # Error-in-success: many connectors return HTTP 200 with an error payload inside. Only the
  # head of the text is inspected, anchored to a status field or a leading error word, so a
  # data row that merely mentions "error" does not qualify. Rows from this path say so.
  def looks_failed: .[0:200] | test("^\\s*\\{?\\s*\"?(status_?[cC]ode|status)\"?\\s*:\\s*\"?[45][0-9]{2}|^\\s*(\\{\\s*\"error\"|Error\\b|ERROR\\b|Request failed|Failed to|Session terminated)");
  ( if .hook_event_name == "PostToolUseFailure" then {e: (.error // "" | tostring), how: "PostToolUseFailure"}
    elif .hook_event_name == "PostToolUse" and ((.tool_response.isError? // .tool_response.is_error? // false) == true)
      then {e: text_of(.tool_response), how: "PostToolUse:isError"}
    elif .hook_event_name == "PostToolUse" and (text_of(.tool_response) | looks_failed)
      then {e: text_of(.tool_response), how: "PostToolUse:error-in-success"}
    else {e: "", how: ""} end ) as $hit
  | $hit.e as $err
  | select($err != "")
  # Not edges: the user said no, or stopped the call.
  | select($err | test("denied by|Permission denied for tool|interrupted by user|Request interrupted"; "i") | not)
  | {
      ts: $now,
      harness: "claude-code",
      event: $hit.how,
      tool: .tool_name,
      project: ((.cwd // "") | gsub($home; "~")),
      session_id: (.session_id // null),
      transcript_path: (.transcript_path // null),
      tool_use_id: (.tool_use_id // null),
      error: ($err | redact | .[0:400])
    }
' 2>/dev/null) || exit 0
[ -n "$row" ] || exit 0

# Fingerprint = sha1 of tool + first 200 chars of the redacted error, so repeats of one
# failure collapse to a count at harvest time. jq has no hash; do it here, fail-open.
fp=$(printf '%s' "$row" | jq -r '.tool + "|" + (.error | .[0:200])' 2>/dev/null | shasum 2>/dev/null | cut -c1-16)
[ -n "$fp" ] && row=$(printf '%s' "$row" | jq -c --arg fp "$fp" '.fp = $fp' 2>/dev/null || printf '%s' "$row")

mkdir -p "$(dirname "$journal")" 2>/dev/null || exit 0
printf '%s\n' "$row" >> "$journal" 2>/dev/null
exit 0
