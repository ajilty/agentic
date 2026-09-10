#!/usr/bin/env bash
# PostToolUseFailure (any tool) and PostToolUse (mcp__.*): append one redacted row per
# tool failure to the local edges journal, so a later `/edges:harvest` can read what this
# session hit without anyone having to remember it.
#
# Input: hook payload JSON on STDIN. PostToolUseFailure carries the error in `.error`;
# an MCP tool that failed inside a successful call carries `isError: true` (or
# `is_error`) on `.tool_response`, with the text in its content. Anything else is
# ignored. Capture only, no judgment: the row is a pointer plus a redacted string.
#
# Journal: ${EDGES_JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/edges/journal.jsonl},
# append-only JSONL. Never inside a repo (it is work observation, not code), user-level
# not per-project (the same tool fails the same way in every repo; the `project` field
# lets harvest filter). Rows carry session_id, transcript_path and tool_use_id so the
# exact call, and the retries after it, are one grep away while the transcript lives.
#
# Redaction happens before the write: emails, URLs, IPv4, UUIDs, long digit runs, and
# home paths become placeholders. Error text is otherwise verbatim, capped at 400 chars.
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
  ( if .hook_event_name == "PostToolUseFailure" then (.error // "" | tostring)
    elif .hook_event_name == "PostToolUse" and ((.tool_response.isError? // .tool_response.is_error? // false) == true)
      then text_of(.tool_response)
    else "" end ) as $err
  | select($err != "")
  # Not edges: the user said no, or stopped the call.
  | select($err | test("denied by|Permission denied for tool|interrupted by user|Request interrupted"; "i") | not)
  | {
      ts: $now,
      harness: "claude-code",
      event: .hook_event_name,
      tool: .tool_name,
      project: ((.cwd // "") | gsub($home; "~")),
      session_id: (.session_id // null),
      transcript_path: (.transcript_path // null),
      tool_use_id: (.tool_use_id // null),
      error: ($err | redact | .[0:400])
    }
  | .fp = ((.tool + "|" + (.error | .[0:200])) | @base64 | .[0:24])
' 2>/dev/null) || exit 0
[ -n "$row" ] || exit 0

mkdir -p "$(dirname "$journal")" 2>/dev/null || exit 0
printf '%s\n' "$row" >> "$journal" 2>/dev/null
exit 0
