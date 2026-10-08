# notice.sh: one line at session start when unharvested rows exist; silence otherwise;
# prunes rows past retention.
N="$HERE/../hooks/notice.sh"
export EDGES_JOURNAL="$TESTHOME/state/edges/notice.jsonl"
CURSOR="${EDGES_JOURNAL%.jsonl}.cursor"
mkdir -p "$(dirname "$EDGES_JOURNAL")"
start_payload(){ jq -cn --arg c "$1" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}'; }
run_out(){ OUT=$(printf '%s' "$2" | bash "$1" 2>/dev/null); RC=$?; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
row(){ jq -cn --arg ts "$1" --arg p "$2" '{ts:$ts,tool:"t",project:$p,error:"e"}'; }

# No journal, or an empty one: silent.
rm -f "$EDGES_JOURNAL" "$CURSOR"
run_out "$N" "$(start_payload /w)"; assert_eq "$RC" 0 "no journal -> 0"; assert_eq "$OUT" "" "no journal -> silent"
: > "$EDGES_JOURNAL"
run_out "$N" "$(start_payload /w)"; assert_eq "$OUT" "" "empty journal -> silent"

# Pending rows: exactly one additionalContext line with total and this-project count.
{ row "$now" "~/gits/x"; row "$now" "~/gits/x"; row "$now" "/elsewhere"; } > "$EDGES_JOURNAL"
run_out "$N" "$(jq -cn --arg c "$HOME/gits/x" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}')"
assert_eq "$RC" 0 "pending -> 0"
assert_eq "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)" "SessionStart" "hookSpecificOutput shape"
ctx=$(printf '%s' "$OUT" | jq -r .systemMessage)
assert_contains "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" "3 potential tool failures" "model copy carries the count"
assert_contains "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)" "Do not mention" "model copy says stay quiet"
assert_contains "$ctx" "3 potential tool failures" "total counted"
assert_contains "$ctx" "(2 from this project)" "this-project count"
assert_contains "$ctx" "/edges:harvest" "points at the harvest skill"
assert_eq "$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')" 1 "exactly one line"

# A cursor written by harvest silences rows at or before it.
printf '%s' "$now" > "$CURSOR"
run_out "$N" "$(start_payload /w)"; assert_eq "$OUT" "" "cursor covers all rows -> silent"
rm -f "$CURSOR"

# Retention: rows older than 30 days are pruned on read, newer ones survive, bad lines dropped.
old=$(date -u -v-40d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-40 days' +%Y-%m-%dT%H:%M:%SZ)
{ row "$old" "/w"; echo 'garbage line'; row "$now" "/w"; } > "$EDGES_JOURNAL"
run_out "$N" "$(start_payload /w)"
assert_eq "$(wc -l < "$EDGES_JOURNAL" | tr -d ' ')" 1 "old and malformed rows pruned"
assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "1 potential tool failure to" "survivor counted"

# Never errors on garbage stdin.
run_out "$N" 'nope'; assert_eq "$RC" 0 "bad stdin -> 0"

# New model: the first id is a silent baseline; an unseen id with model-tagged edges installed
# pends an audit that keeps showing until harvest deletes the marker. Ids stay local.
MODELS="${EDGES_JOURNAL%.jsonl}.models"; AUDIT="${EDGES_JOURNAL%.jsonl}.audit"
export EDGES_SKILLS_DIR="$TESTHOME/skills"
mkdir -p "$EDGES_SKILLS_DIR/working-with-a" "$EDGES_SKILLS_DIR/working-with-b"
printf -- '- edge one <!-- decays: model -->\n- edge two\n' > "$EDGES_SKILLS_DIR/working-with-a/SKILL.md"
printf -- '- edge three <!-- decays: model -->\n' > "$EDGES_SKILLS_DIR/working-with-b/SKILL.md"
model_payload(){ jq -cn --arg m "$1" '{hook_event_name:"SessionStart",source:"startup",cwd:"/w",model:$m}'; }
rm -f "$EDGES_JOURNAL" "$CURSOR" "$MODELS" "$AUDIT"

run_out "$N" "$(model_payload m-old)"; assert_eq "$OUT" "" "first model -> silent baseline"
assert_eq "$(cat "$MODELS")" "m-old" "baseline recorded"
run_out "$N" "$(model_payload 'm-old[1m]')"; assert_eq "$OUT" "" "context suffix is the same model"
run_out "$N" "$(jq -cn '{hook_event_name:"SessionStart",source:"startup",cwd:"/w"}')"; assert_eq "$OUT" "" "no model field -> silent"

run_out "$N" "$(model_payload m-new)"
ctx=$(printf '%s' "$OUT" | jq -r .systemMessage)
assert_contains "$ctx" "2 model-tagged edges to re-check" "unseen model counts tagged edges"
assert_contains "$ctx" "/edges:harvest audit" "points at the audit mode"
assert_eq "$(cat "$AUDIT")" "m-new" "audit marked pending"
run_out "$N" "$(model_payload m-old)"
assert_contains "$(printf '%s' "$OUT" | jq -r .systemMessage)" "model-tagged" "pending audit persists across sessions"
rm -f "$AUDIT"
run_out "$N" "$(model_payload m-new)"; assert_eq "$OUT" "" "harvest cleared the marker; seen model -> silent"

# Both pending: still exactly one line, naming both commands.
row "$now" "/w" > "$EDGES_JOURNAL"
run_out "$N" "$(model_payload m-newer)"
ctx=$(printf '%s' "$OUT" | jq -r .systemMessage)
assert_contains "$ctx" "1 potential tool failure to harvest, and 2 model-tagged edges" "both clauses"
assert_eq "$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')" 1 "both -> exactly one line"

# Unseen model with nothing tagged installed: silent (the marker waits for tagged edges).
rm -f "$EDGES_JOURNAL" "$AUDIT"
: > "$EDGES_SKILLS_DIR/working-with-a/SKILL.md"; : > "$EDGES_SKILLS_DIR/working-with-b/SKILL.md"
run_out "$N" "$(model_payload m-newest)"; assert_eq "$OUT" "" "no tagged edges -> silent"
unset EDGES_SKILLS_DIR
