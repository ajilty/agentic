# Group unharvested failure-journal rows into harvest candidates.
#   jq -s --arg since "$(cat journal.cursor)" -f count.jq journal.jsonl
# Key: the tool's own name (server alias dropped, so one quirk on two servers
# is one row) plus the error head with whitespace collapsed and every number
# masked (so errors that differ only in a size or count collapse).
map(select(.ts > $since))
| group_by([(.tool|split("__")|last),
            (.error|gsub("\\s+";" ")|gsub("[0-9][0-9,.]*";"#")|.[0:120])])
| map({n: length, sessions: (map(.session_id)|unique|length),
       servers: (map(.tool|split("__")[1] // "")|unique|join(",")),
       tool: (.[0].tool|split("__")|last),
       first: (map(.ts)|min), last: (map(.ts)|max),
       error: (.[0].error|gsub("\\s+";" ")|.[0:160])})
| sort_by(-.n)
