# journal.sh: one redacted row per tool failure, append-only, never noisy.
J="$HERE/../hooks/journal.sh"
export EDGES_JOURNAL="$TESTHOME/state/edges/journal.jsonl"
rows(){ [ -f "$EDGES_JOURNAL" ] && wc -l < "$EDGES_JOURNAL" | tr -d ' ' || echo 0; }
last(){ tail -n1 "$EDGES_JOURNAL"; }

fail_payload(){ jq -cn --arg t "$1" --arg e "$2" --arg home "$HOME" \
  '{hook_event_name:"PostToolUseFailure",session_id:"s1",transcript_path:($home+"/.claude/projects/p/s1.jsonl"),tool_use_id:"toolu_1",cwd:($home+"/gits/x"),tool_name:$t,tool_input:{},error:$e}'; }
mcp_payload(){ jq -cn --arg t "$1" --arg e "$2" --argjson iserr "$3" \
  '{hook_event_name:"PostToolUse",session_id:"s1",cwd:"/w",tool_name:$t,tool_input:{},tool_response:{isError:$iserr,content:[{type:"text",text:$e}]}}'; }

# A plain failure lands as one row with pointers and the tool name.
run_hook "$J" "$(fail_payload mcp__splunk__run_query 'Request failed: Session is not logged in.')"
assert_eq "$RC" 0 "failure -> exit 0"; assert_eq "$ERR" "" "failure -> silent"; assert_eq "$(rows)" 1 "one row appended"
assert_eq "$(last | jq -r .tool)" "mcp__splunk__run_query" "tool recorded"
assert_eq "$(last | jq -r .event)" "PostToolUseFailure" "event recorded"
assert_eq "$(last | jq -r .tool_use_id)" "toolu_1" "tool_use_id pointer kept"
assert_eq "$(last | jq -r .transcript_path)" "$HOME/.claude/projects/p/s1.jsonl" "transcript pointer kept"
assert_eq "$(last | jq -r .project)" "~/gits/x" "project recorded with home collapsed"
assert_contains "$(last | jq -r .error)" "Session is not logged in" "error text verbatim"
assert_eq "$(last | jq -r .harness)" "claude-code" "harness stamped"
[ -n "$(last | jq -r .fp)" ] && pass || fail "fingerprint present"

# Redaction before the write: identifiers never reach disk in the clear.
run_hook "$J" "$(fail_payload Bash "user alice@corp.example failed at https://tenant.example.com/api/v1 from 10.20.30.40 id 3f2a1b4c-1111-2222-3333-444455556666 acct 123456789012 in $HOME/secret")"
e=$(last | jq -r .error)
assert_contains "$e" "<email>" "email redacted"; assert_contains "$e" "<url>" "url redacted"
assert_contains "$e" "<ip>" "ip redacted"; assert_contains "$e" "<uuid>" "uuid redacted"
assert_contains "$e" "<n>" "long digit run redacted"; assert_contains "$e" "~/secret" "home path collapsed"
case "$e" in *alice*|*tenant.example*|*10.20.30*|*123456789012*) fail "identifier leaked: $e" ;; *) pass ;; esac

# Error text is capped so one giant stack trace cannot bloat the journal.
run_hook "$J" "$(fail_payload Bash "$(head -c 5000 /dev/zero | tr '\0' x)")"
[ "$(last | jq -r '.error | length')" -le 400 ] && pass || fail "error capped at 400 chars"

# MCP error-in-success is captured; a clean MCP result is not.
n=$(rows)
run_hook "$J" "$(mcp_payload mcp__wiz__list_issues 'Failed to convert free text to graph query' true)"
assert_eq "$(rows)" $((n+1)) "mcp isError -> row"; assert_eq "$(last | jq -r .event)" "PostToolUse" "mcp row event"
assert_contains "$(last | jq -r .error)" "Failed to convert" "mcp error text taken from content"
run_hook "$J" "$(mcp_payload mcp__wiz__list_issues 'ok' false)"
assert_eq "$(rows)" $((n+1)) "clean mcp result -> no row"

# The user saying no, or stopping a call, is not an edge.
n=$(rows)
run_hook "$J" "$(fail_payload Bash 'Permission denied for tool by user')"
run_hook "$J" "$(fail_payload Bash 'Request interrupted by user')"
assert_eq "$(rows)" "$n" "denials and interrupts skipped"

# Garbage in, nothing out, exit 0.
n=$(rows)
run_hook "$J" 'not json'; assert_eq "$RC" 0 "bad json -> 0"; assert_eq "$(rows)" "$n" "bad json -> no row"
run_hook "$J" ''; assert_eq "$RC" 0 "empty stdin -> 0"
run_hook "$J" '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":"fine"}'; assert_eq "$(rows)" "$n" "non-mcp success ignored"

# Every row is valid JSONL.
jq -e . "$EDGES_JOURNAL" >/dev/null 2>&1 && pass || fail "journal is not valid JSONL"
