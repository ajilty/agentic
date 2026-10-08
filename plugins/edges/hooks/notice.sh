#!/usr/bin/env bash
# SessionStart (startup|resume): one line, only when something is waiting for a harvest:
# journal failures no harvest has looked at yet, or model-tagged edges to re-check because
# a model this machine has not run before is in use. Also prunes journal rows older than
# 30 days, matched to the harness's default transcript retention, so the journal cannot
# grow unbounded and never points at transcripts that are gone.
#
# "Looked at" is a cursor file beside the journal holding an ISO timestamp; harvest
# writes it after presenting candidates. Rows newer than the cursor are pending.
#
# "New model" is a model id (context-window suffix stripped) missing from the seen-models
# file beside the journal. The first id ever seen is a silent baseline. A new id marks an
# audit as pending in the `.audit` file; it stays pending, and the line keeps showing
# while any installed edge carries `<!-- decays: model -->`, until `/edges:harvest audit`
# presents the tagged edges and deletes the marker. Model ids stay on this machine.
#
# Contract: exit 0 always; on anything pending emit one JSON object carrying the same line
# as systemMessage (shown to the user) and additionalContext (seen by the model). Silent
# otherwise. Fail-open on missing jq. This is the entire user-facing surface of the
# journal: never mid-session, never more than one line.

set -u
command -v jq >/dev/null 2>&1 || exit 0
journal="${EDGES_JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/edges/journal.jsonl}"
cursor_file="${journal%.jsonl}.cursor"
models_file="${journal%.jsonl}.models"
audit_file="${journal%.jsonl}.audit"
skills_dir="${EDGES_SKILLS_DIR:-$(dirname "$0")/../skills}"
retention_days="${EDGES_JOURNAL_RETENTION_DAYS:-30}"

payload=$(cat 2>/dev/null)
here=$(printf '%s' "$payload" | jq -r --arg home "$HOME" '(.cwd // "") | gsub($home; "~")' 2>/dev/null)
model=$(printf '%s' "$payload" | jq -r '(.model // "") | strings | sub("\\[.*\\]$"; "")' 2>/dev/null)

# Journal: prune in place, atomically (a malformed line is dropped rather than kept
# forever), then count rows newer than the cursor.
total=0 mine=0
if [ -s "$journal" ]; then
  cursor=$(cat "$cursor_file" 2>/dev/null || printf '1970-01-01T00:00:00Z')
  cutoff=$(date -u -v-"${retention_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${retention_days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || cutoff="1970-01-01T00:00:00Z"
  if tmp=$(mktemp "${journal}.XXXXXX" 2>/dev/null); then
    jq -cR --arg cutoff "$cutoff" 'fromjson? | select(type == "object" and (.ts // "") >= $cutoff)' "$journal" > "$tmp" 2>/dev/null && mv -f "$tmp" "$journal" || rm -f "$tmp"
  fi
  if [ -s "$journal" ]; then
    read -r total mine < <(jq -rs --arg cursor "$cursor" --arg here "$here" '
      map(select((.ts // "") > $cursor))
      | "\(length) \(map(select(.project == $here)) | length)"' "$journal" 2>/dev/null) || { total=0 mine=0; }
  fi
fi

# Model: record the id; a new one after the baseline marks an audit pending.
if [ -n "$model" ] && mkdir -p "$(dirname "$models_file")" 2>/dev/null; then
  if [ ! -s "$models_file" ]; then
    printf '%s\n' "$model" > "$models_file" 2>/dev/null
  elif ! grep -qxF -- "$model" "$models_file" 2>/dev/null; then
    printf '%s\n' "$model" >> "$models_file" 2>/dev/null
    printf '%s\n' "$model" > "$audit_file" 2>/dev/null
  fi
fi
tagged=0
[ -e "$audit_file" ] && tagged=$(cat "$skills_dir"/*/SKILL.md 2>/dev/null | grep -o '<!-- decays: model -->' | wc -l | tr -d ' ')

failures="" edges=""
if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
  plural="failures"; [ "$total" -eq 1 ] && plural="failure"
  failures="${total} potential tool ${plural} to harvest"
  [ "${mine:-0}" -gt 0 ] && [ "$mine" -ne "$total" ] && failures="${failures} (${mine} from this project)"
fi
if [ "${tagged:-0}" -gt 0 ] 2>/dev/null; then
  plural="edges"; [ "$tagged" -eq 1 ] && plural="edge"
  edges="${tagged} model-tagged ${plural} to re-check on a new model"
fi

if [ -n "$failures" ] && [ -n "$edges" ]; then
  msg="⚠️ Edges plug-in has ${failures}, and ${edges}. Run \`/edges:harvest\` for the failures and \`/edges:harvest audit\` for the edges."
elif [ -n "$failures" ]; then
  msg="⚠️ Edges plug-in has ${failures}. Run \`/edges:harvest\` to learn from them."
elif [ -n "$edges" ]; then
  msg="⚠️ Edges plug-in has ${edges}. Run \`/edges:harvest audit\` to re-check them."
else
  exit 0
fi
# systemMessage is what the user sees; additionalContext is what the model sees. The model's
# copy adds the instruction not to bring it up, so the user's one line stays the only line.
jq -cn --arg m "$msg" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:($m + " Do not mention the journal unless the user asks or invokes harvest.")}}'
exit 0
