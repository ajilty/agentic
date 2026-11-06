# Tier 3c: the router's intake-clarification decision is JOURNALED (SKILL.md loop step 3), so it
# becomes a checkable trace instead of invisible router-context behavior. Today a
# clarification skill runs in router context and leaves NO ledger event, so nothing
# can verify it fired. `ledger.sh clarify <skill> [ticket]` records the decision
# (which skill was selected, first-present-wins), and the conformance checker can then
# assert it happened on an ambiguous goal.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"
board=".agents/runs/orchestrate/board.jsonl"

# journal a clarify decision
bash "$R" clarify grill-with-docs >/dev/null 2>&1
assert_eq "$?" "0" "clarify subcommand exists and exits 0"
grep -q '"event":"clarify"' "$board"            && pass || fail "clarify event journaled"
grep -q '"skill":"grill-with-docs"' "$board"    && pass || fail "clarify records the selected skill"

# the conformance checker can assert the clarify step fired with the first-present skill
bash "$R" conformance clarify:grill-with-docs >/dev/null 2>&1
assert_eq "$?" "0" "conformance matches the clarify trace"
# and distinguishes WHICH clarification skill fired (not just that one did)
bash "$R" conformance clarify:brainstorming >/dev/null 2>&1
assert_eq "$?" "1" "conformance distinguishes which clarification skill fired"

# missing skill arg -> nonzero (don't journal an empty decision)
bash "$R" clarify >/dev/null 2>&1
[ "$?" -ne 0 ] && pass || fail "clarify with no skill -> nonzero"

cd /; rm -rf "$d"
