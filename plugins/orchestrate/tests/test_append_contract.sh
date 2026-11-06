# ADR-0030 — `append` must out-earn `echo >>`: it stamps ts when absent and warns
# on a non-canonical event, but NEVER drops the line. Field measurement behind it:
# 311/503 board lines shipped without ts because the old append was a passthrough
# routers rationally bypassed; only `done`, whose helper does real work, hit 100%.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"
B=".agents/runs/orchestrate/board.jsonl"

# ts stamped when absent, payload preserved
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}'
tail -1 "$B" | grep -q '^{"ts":"20' && pass || fail "append stamps ts when absent"
tail -1 "$B" | grep -q '"event":"intake"' && pass || fail "append preserves the payload after stamping"

# an explicit ts is preserved and not double-stamped
bash "$R" append '{"ts":"2026-01-01T00:00:00Z","ticket":"T1","event":"verdict","verdict":"APPROVED"}'
tail -1 "$B" | grep -q '"ts":"2026-01-01T00:00:00Z"' && pass || fail "append preserves an explicit ts"
assert_eq "$(tail -1 "$B" | grep -o '"ts":' | wc -l | tr -d ' ')" 1 "append does not double-stamp ts"

# canonical event -> silent; non-canonical -> stderr warning; line kept either way
w="$(bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"researcher","dispatch_id":"d1","slug":"s1"}' 2>&1)"
[ -z "$w" ] && pass || fail "no warning on a canonical event ($w)"
w="$(bash "$R" append '{"ticket":"T1","event":"debugging_note"}' 2>&1)"
case "$w" in *"not canonical"*) pass;; *) fail "warns on a non-canonical event ($w)";; esac
tail -1 "$B" | grep -q '"event":"debugging_note"' && pass || fail "a non-canonical line is still appended (append-only: never dropped)"
w="$(bash "$R" append '{"ticket":"T1","note":"free-form"}' 2>&1)"
case "$w" in *"not canonical"*) pass;; *) fail "warns when the event field is missing ($w)";; esac

# denied (ADR-0032) is canonical -> silent
w="$(bash "$R" append '{"event":"denied","hook":"run-scope","persona":"verifier","note":"git checkout"}' 2>&1)"
[ -z "$w" ] && pass || fail "denied is a canonical event ($w)"

# goal drift guard: a goal without "note" warns (reground's anchor reads note); with note, silent
w="$(bash "$R" append '{"event":"goal","goal":"hand-built wrong field","base":"master"}' 2>&1)"
case "$w" in *'without a "note"'*) pass;; *) fail "warns on a goal event missing note ($w)";; esac
w="$(bash "$R" append '{"event":"goal","note":"proper anchor","base":"master"}' 2>&1)"
[ -z "$w" ] && pass || fail "goal with note is silent ($w)"

# suite invariant that would have caught the field gap: every line carries ts
assert_eq "$(grep -cv '"ts":"' "$B" || true)" 0 "every board line carries ts"

# 0.9.0 canonical set drops lease-conflict and gate-blocked (read on old boards, never written)
w="$(bash "$R" append '{"ticket":"T1","event":"lease-conflict"}' 2>&1)"
case "$w" in *"not canonical"*) pass;; *) fail "lease-conflict is no longer canonical ($w)";; esac
w="$(bash "$R" append '{"ticket":"T1","event":"gate-blocked"}' 2>&1)"
case "$w" in *"not canonical"*) pass;; *) fail "gate-blocked is no longer canonical ($w)";; esac
