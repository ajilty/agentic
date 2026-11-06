# `ledger.sh done <ticket>` is guidance, not a gate (ADR-0040). It always appends the done
# event; a non-T0 lane closed without a verdict gets a stderr warning (exit 0), and
# verify_coverage in `metrics` is the retrospective signal. T0 (the oracle is the check)
# and a lane that has a verdict close silently.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
board=".agents/runs/orchestrate/board.jsonl"

# 1) T1 without a verdict -> done appended, warning on stderr, exit 0
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}'
err="$(bash "$R" done T1 2>&1 >/dev/null)"; code=$?
assert_eq "$code" "0" "T1 without a verdict -> exit 0"
grep -q '"ticket":"T1".*"event":"done"' "$board" && pass || fail "done event appended despite the missing verdict"
case "$err" in *warning*T1*"without a Verifier verdict"*"tier=T1"*) pass;; *) fail "warning names ticket and tier: $err";; esac
assert_eq "$(bash "$R" metrics | grep -o 'verify_coverage=[0-9/]*')" "verify_coverage=0/1" "verify_coverage shows the gap"
cd /; rm -rf "$d"

# 2) T1 with a verdict -> no warning
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T2","event":"intake","tier":"T1"}'
bash "$R" append '{"ticket":"T2","event":"verdict","verdict":"APPROVED"}'
err="$(bash "$R" done T2 2>&1 >/dev/null)"; assert_eq "$?" "0" "T1 with a verdict -> exit 0"
assert_eq "$err" "" "T1 with a verdict -> no warning"
grep -q '"ticket":"T2".*"event":"done"' "$board" && pass || fail "done event appended for the verified lane"
cd /; rm -rf "$d"

# 3) T0 without a verdict -> no warning
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T3","event":"intake","tier":"T0"}'
err="$(bash "$R" done T3 2>&1 >/dev/null)"; assert_eq "$?" "0" "T0 without a verdict -> exit 0"
assert_eq "$err" "" "T0 without a verdict -> no warning"
cd /; rm -rf "$d"

# 4) field order does not matter: a hand-appended intake/verdict with event before ticket
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"event":"intake","ticket":"T4","tier":"T0"}'
err="$(bash "$R" done T4 2>&1 >/dev/null)"; assert_eq "$err" "" "T0 intake with event before ticket -> no warning"
bash "$R" append '{"event":"intake","ticket":"T5","tier":"T1"}'
bash "$R" append '{"verdict":"REJECTED","event":"verdict","ticket":"T5"}'
err="$(bash "$R" done T5 2>&1 >/dev/null)"; assert_eq "$err" "" "verdict with fields reordered still counts"
assert_eq "$(bash "$R" retries T5)" "1" "retries counts a REJECTED verdict whose verdict key precedes ticket"
cd /; rm -rf "$d"
