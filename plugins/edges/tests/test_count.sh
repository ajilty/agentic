# count.jq: harvest grouping drops the server alias, masks numbers, counts sessions.
Q="$HERE/../skills/harvest/count.jq"
r(){ jq -cn --arg ts "$1" --arg t "$2" --arg s "$3" --arg e "$4" '{ts:$ts,tool:$t,session_id:$s,error:$e}'; }
J="$TESTHOME/count.jsonl"
{ r 2026-01-02T00:00:00Z mcp__wiz-a__execute s1 "Resource not found"
  r 2026-01-03T00:00:00Z mcp__wiz-b__execute s2 "Resource not found"
  r 2026-01-03T00:00:01Z mcp__wiz-b__execute s2 "Resource not found"
  r 2026-01-04T00:00:00Z mcp__x__read s3 "Error: result (83,258 characters across 12 lines) exceeds"
  r 2026-01-04T00:00:01Z mcp__x__read s3 "Error: result (1,476,290 characters across 5,660 lines) exceeds"
  r 2026-01-05T00:00:00Z Bash s3 "Exit code 1
boom"
  r 2025-12-31T00:00:00Z mcp__wiz-a__execute s0 "Resource not found"; } > "$J"
out=$(jq -s --arg since 2026-01-01T00:00:00Z -f "$Q" "$J")
assert_eq "$(jq length <<<"$out")" 3 "three groups past the cursor"
assert_eq "$(jq -r '.[0] | "\(.n) \(.sessions) \(.servers) \(.tool)"' <<<"$out")" "3 2 wiz-a,wiz-b execute" "server alias dropped, sessions counted, sorted by hits"
assert_eq "$(jq -r '.[] | select(.tool=="read") | .n' <<<"$out")" 2 "size-only differences collapse"
assert_eq "$(jq -r '.[] | select(.tool=="Bash") | .servers' <<<"$out")" "" "built-in tool rows group without a server"
assert_eq "$(jq -r '[.[].n] | add' <<<"$out")" 6 "rows at or before the cursor excluded"
