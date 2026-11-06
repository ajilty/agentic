# test_goal_anchor.sh — the run-level `goal` event anchors the board so a CLEAN board
# (no open lanes) still carries the north star + a pointer to the plan across compaction,
# instead of resume depending on an external prose doc (ADR-0020).
L="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"
board=".agents/runs/orchestrate/board.jsonl"

# goal journals a run-level event (note + spec pointer), with NO ticket field
bash "$L" goal "wire up rate limiting" "docs/adr/0079-topology.md"
grep -q '"event":"goal"' "$board"                     && pass || fail "goal event journaled"
grep -q '"note":"wire up rate limiting"' "$board"     && pass || fail "goal records the note"
grep -q '"spec":"docs/adr/0079-topology.md"' "$board" && pass || fail "goal records the plan pointer"
grep -q '"ticket"' "$board" && fail "goal is run-level: it must carry no ticket field" || pass

# reground with NO open lanes still surfaces the goal + plan pointer
out="$(bash "$L" reground 2>&1)"
case "$out" in *"GOAL: wire up rate limiting"*) pass;; *) fail "reground surfaces the goal (got: $out)";; esac
case "$out" in *"resume from plan: docs/adr/0079-topology.md"*) pass;; *) fail "reground surfaces the plan pointer";; esac
case "$out" in *"no open lanes"*) pass;; *) fail "reground still reports no open lanes";; esac

# latest goal wins (re-journaled with an updated spec pointer -> tail -1)
bash "$L" goal "wire up rate limiting" "docs/adr/0080-final.md"
out2="$(bash "$L" reground 2>&1)"
case "$out2" in *"0080-final.md"*) pass;; *) fail "reground surfaces the LATEST goal (tail -1)";; esac

# optional base (integration branch, guard-merge-base floor ADR-0027) journals when given
bash "$L" goal "wire up rate limiting" "docs/adr/0080-final.md" "blank-slate"
grep -q '"base":"blank-slate"' "$board" && pass || fail "goal records the integration base"

# the model-policy argument is retired (ADR-0040): a 4th arg is ignored, never journaled
bash "$L" goal "wire up rate limiting" "docs/adr/0080-final.md" "blank-slate" "quick"
grep -q '"model_policy"' "$board" && fail "goal no longer writes model_policy" || pass

# missing note -> nonzero (don't journal an empty goal)
bash "$L" goal >/dev/null 2>&1
[ "$?" -ne 0 ] && pass || fail "goal with no note -> nonzero"

cd /; rm -rf "$d"
