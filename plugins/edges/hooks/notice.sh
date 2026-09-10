#!/usr/bin/env bash
# SessionStart (startup|resume): one line, only when the edges journal holds failures
# that no harvest has looked at yet. Also prunes rows older than 30 days, matched to the
# harness's default transcript retention, so the journal cannot grow unbounded and never
# points at transcripts that are gone.
#
# "Looked at" is a cursor file beside the journal holding an ISO timestamp; harvest
# writes it after presenting candidates. Rows newer than the cursor are pending.
#
# Contract: exit 0 always; on pending rows emit one JSON object carrying the same line as
# systemMessage (shown to the user) and additionalContext (seen by the model). Silent
# otherwise. Fail-open on missing jq. This is the entire user-facing surface of the
# journal: never mid-session, never
# more than one line.

set -u
command -v jq >/dev/null 2>&1 || exit 0
journal="${EDGES_JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/edges/journal.jsonl}"
[ -s "$journal" ] || exit 0
cursor_file="${journal%.jsonl}.cursor"
cursor=$(cat "$cursor_file" 2>/dev/null || printf '1970-01-01T00:00:00Z')
retention_days="${EDGES_JOURNAL_RETENTION_DAYS:-30}"
cutoff=$(date -u -v-"${retention_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${retention_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || cutoff="1970-01-01T00:00:00Z"

# Prune in place, atomically; a malformed line is dropped rather than kept forever.
tmp=$(mktemp "${journal}.XXXXXX" 2>/dev/null) || exit 0
jq -cR --arg cutoff "$cutoff" 'fromjson? | select(type == "object" and (.ts // "") >= $cutoff)' "$journal" > "$tmp" 2>/dev/null && mv -f "$tmp" "$journal" || rm -f "$tmp"
[ -s "$journal" ] || exit 0

payload=$(cat 2>/dev/null)
here=$(printf '%s' "$payload" | jq -r --arg home "$HOME" '(.cwd // "") | gsub($home; "~")' 2>/dev/null)

read -r total mine oldest < <(jq -rs --arg cursor "$cursor" --arg here "$here" '
  map(select((.ts // "") > $cursor))
  | "\(length) \(map(select(.project == $here)) | length) \((map(.ts) | min) // "")"' "$journal" 2>/dev/null) || exit 0
[ "${total:-0}" -gt 0 ] 2>/dev/null || exit 0

msg="edges journal: ${total} tool failure(s) captured since your last harvest"
[ "${mine:-0}" -gt 0 ] && msg="${msg} (${mine} from this project)"
msg="${msg}, oldest ${oldest%%T*}. /edges:harvest reads them; nothing else will mention this."
# systemMessage is what the user sees; additionalContext is what the model sees. The model's
# copy adds the instruction not to bring it up, so the user's one line stays the only line.
jq -cn --arg m "$msg" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:($m + " Do not mention the journal unless the user asks or invokes harvest.")}}'
exit 0
