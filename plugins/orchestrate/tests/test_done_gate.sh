# Tier 3c — VERIFICATION IS NOT OPTIONAL (the enforcement half). The infra-log analysis
# showed the router self-verifies inline and ships without a Verifier. Teaching alone
# (context-economy §2a′, §2b) didn't override that pull, so `ledger.sh done <ticket>` is
# FAIL-CLOSED: a verifying lane (T1/T2) may not be marked done without a verdict on the
# board. T0 (one Implementer vs the oracle — the oracle IS the check) is exempt. Unknown
# tier -> require a verdict (fail-closed). This makes "ship unverified" impossible, not
# just discouraged.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
board=".agents/runs/orchestrate/board.jsonl"

# 1) T2 WITH a verdict -> done allowed
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T2"}'
bash "$R" append '{"ticket":"T1","event":"verdict","verdict":"APPROVED"}'
bash "$R" done T1 >/dev/null 2>&1
assert_eq "$?" "0" "T2 with a verdict -> done allowed"
grep -q '"ticket":"T1".*"event":"done"' "$board" && pass || fail "done event journaled for the verified lane"
cd /; rm -rf "$d"

# 2) T2 (T2-min) WITHOUT a verdict -> REFUSED (the load-bearing gate)
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T2","event":"intake","tier":"T2-min"}'
out="$(bash "$R" done T2 2>&1)"; code=$?
assert_eq "$code" "3" "T2 without a verdict -> done REFUSED (verification not optional)"
grep -q '"event":"done"' "$board" 2>/dev/null && fail "no done event should be written when refused" || pass
case "$out" in *erif*) pass;; *) fail "refusal names the missing verifier/verdict: $out";; esac
cd /; rm -rf "$d"

# 3) T0 WITHOUT a verdict -> allowed (the oracle is the check; no Verifier in a T0 lane)
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T3","event":"intake","tier":"T0"}'
bash "$R" done T3 >/dev/null 2>&1
assert_eq "$?" "0" "T0 without a verdict -> done allowed (oracle is the check)"
cd /; rm -rf "$d"

# 3b) field order does not matter: a verdict journaled event-first still counts
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"event":"intake","ticket":"T3b","tier":"T2"}'
bash "$R" append '{"event":"verdict","ticket":"T3b","verdict":"APPROVED"}'
bash "$R" done T3b >/dev/null 2>&1
assert_eq "$?" "0" "event-first verdict row satisfies the done gate"
cd /; rm -rf "$d"

# 4) UNKNOWN tier (no intake) without a verdict -> fail-closed REFUSE
d="$(mktemp_repo)"; cd "$d"
bash "$R" done T4 >/dev/null 2>&1
assert_eq "$?" "3" "unknown tier without a verdict -> fail-closed refuse"
cd /; rm -rf "$d"
