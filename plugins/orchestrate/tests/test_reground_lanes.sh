# Reground lists every lane that is not closed, so nothing parked disappears after
# compaction, and treats an in-flight actuator as a writer, never a re-dispatch candidate.
# Also: one verdict row per three-lens round, plan-mode verdicts kept out of the implementer
# retry budget and verify_coverage, prod confirmations kept out of the escalation counts,
# control characters stripped from free text, and the whole thing under macOS bash 3.2.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"; git commit -qm init --allow-empty

# --- an in-flight actuator (prod-ack journaled, dispatched, no returned) is an OPEN WRITER
bash "$R" decision A1 prod-ack:tfstate:prod/net "" "approved: ship it"
bash "$R" append '{"ticket":"A1","event":"dispatched","persona":"actuator","dispatch_id":"a1"}'
out="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "in-flight actuator is reported, not a HALT"
case "$out" in *"OPEN WRITER   ticket=A1 persona=actuator -> in flight or crashed; never re-dispatch an actuator without confirming with the operator"*) pass;; *) fail "actuator reported as an open writer ($out)";; esac
case "$out" in *"OPEN READONLY"*A1*|*"re-dispatch (no result"*A1*) fail "an actuator must never read as a re-dispatch candidate ($out)";; *) pass;; esac

# --- parked lanes stay visible: returned, verdict (each kind), fork, intake
bash "$R" append '{"ticket":"L1","event":"returned","persona":"implementer","status":"DONE","branch":"b1"}'
bash "$R" append '{"ticket":"L2","event":"verdict","verdict":"APPROVED"}'
bash "$R" append '{"ticket":"L3","event":"verdict","verdict":"REJECTED"}'
bash "$R" append '{"ticket":"L4","event":"fork","state":"halted","fork_id":"F1"}'
bash "$R" append '{"ticket":"L5","event":"intake","tier":"T2"}'
bash "$R" append '{"ticket":"L6","event":"verdict","verdict":"APPROVED","mode":"plan"}'
bash "$R" append '{"ticket":"L7","event":"verdict","verdict":"INCONSISTENT_ORACLE"}'
out="$(bash "$R" reground 2>&1)"
case "$out" in *"ticket=L1 last=returned"*"verifier"*) pass;; *) fail "returned lane listed as awaiting its verdict ($out)";; esac
case "$out" in *"ticket=L2 last=verdict:APPROVED -> awaiting landing"*) pass;; *) fail "approved lane listed as awaiting landing";; esac
case "$out" in *"ticket=L3 last=verdict:REJECTED -> awaiting fix"*) pass;; *) fail "rejected lane listed as awaiting fix";; esac
case "$out" in *"ticket=L4 last=fork -> halted, awaiting the operator"*) pass;; *) fail "halted fork listed";; esac
case "$out" in *"ticket=L5 last=intake -> not yet dispatched"*) pass;; *) fail "intake-only lane listed";; esac
case "$out" in *"ticket=L6 last=plan-verdict:APPROVED"*) pass;; *) fail "plan-mode verdict listed as spec signed";; esac
case "$out" in *"ticket=L7 last=verdict:INCONSISTENT_ORACLE -> the operator"*) pass;; *) fail "inconsistent oracle listed for the operator";; esac
case "$out" in *"board: no open lanes"*) fail "parked lanes must not read as an empty board";; *) pass;; esac
# a closed lane is not listed
bash "$R" done L2 2>/dev/null
case "$(bash "$R" reground 2>&1)" in *"ticket=L2 "*) fail "a closed lane is not listed";; *) pass;; esac

# --- three-lens verification: one verdict row per round, so retries counts rounds
bash "$R" append '{"ticket":"V1","event":"dispatched","persona":"verifier","dispatch_id":"act1","lens":"act"}'
bash "$R" append '{"ticket":"V1","event":"dispatched","persona":"verifier","dispatch_id":"fit1","lens":"fit"}'
bash "$R" append '{"ticket":"V1","event":"dispatched","persona":"verifier","dispatch_id":"brk1","lens":"break"}'
bash "$R" append '{"ticket":"V1","event":"verdict","verdict":"REJECTED","round":"1","artifact":"verdicts/V1.round1.md"}'
assert_eq "$(bash "$R" retries V1)" "1" "round 1 of three lenses spends one retry"
bash "$R" append '{"ticket":"V1","event":"verdict","verdict":"REJECTED","round":"2","artifact":"verdicts/V1.round2.md"}'
assert_eq "$(bash "$R" retries V1)" "2" "round 2 spends the second"
# a plan-mode reject judges the spec: it spends no implementer retry
bash "$R" append '{"ticket":"V2","event":"verdict","verdict":"REJECTED","mode":"plan"}'
assert_eq "$(bash "$R" retries V2)" "0" "plan-mode REJECTED is not an implementer retry"

# --- a plan-mode verdict does not satisfy done or verify_coverage
bash "$R" append '{"ticket":"P1","event":"intake","tier":"T2"}'
bash "$R" append '{"ticket":"P1","event":"verdict","verdict":"APPROVED","mode":"plan"}'
err="$(bash "$R" done P1 2>&1 >/dev/null)"
case "$err" in *"without a Verifier verdict"*) pass;; *) fail "done warns when only a plan-mode verdict exists ($err)";; esac
# verify_coverage is field-order independent (event before ticket) and skips plan mode
bash "$R" append '{"event":"verdict","ticket":"P2","verdict":"APPROVED"}'
bash "$R" done P2 2>/dev/null
m="$(bash "$R" metrics P1)"; case "$m" in *"verify_coverage=0/1"*) pass;; *) fail "plan-mode verdict not counted as coverage ($m)";; esac
m="$(bash "$R" metrics P2)"; case "$m" in *"verify_coverage=1/1"*) pass;; *) fail "verify_coverage reads event-before-ticket rows ($m)";; esac

# --- prod confirmations are counted apart from forks/decisions
m="$(bash "$R" metrics A1)"
case "$m" in *"decisions=0"*"prod_acks=1"*) pass;; *) fail "prod-ack counted as prod_acks, not a decision ($m)";; esac

# --- free text: control characters other than newline/CR/tab are dropped (valid JSON)
bash "$R" decision C1 fork-1 "" "$(printf 'a\001b\nc\td\033e')"
bash "$R" goal "$(printf 'goal\002 text')" docs/spec.md main opus
if command -v jq >/dev/null 2>&1; then
  grep '"ticket":"C1"' .agents/runs/orchestrate/board.jsonl | jq -e '.note=="ab c de"' >/dev/null 2>&1 && pass || fail "decision note stripped of control characters"
  grep '"event":"goal"' .agents/runs/orchestrate/board.jsonl | tail -1 | jq -e '.note=="goal text" and .main_model=="opus"' >/dev/null 2>&1 && pass || fail "goal journals main_model and strips control characters"
fi

# --- macOS bash 3.2: reground must run (no associative arrays)
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' 2>/dev/null; then
  out="$(/bin/bash "$R" reground 2>&1)"; rc=$?
  assert_eq "$rc" "0" "reground runs under /bin/bash 3.2"
  case "$out" in *"OPEN WRITER   ticket=A1 persona=actuator"*) pass;; *) fail "bash 3.2 reground output ($out)";; esac
else
  echo "(skip bash 3.2 reground: /bin/bash is bash 4+)"
fi
cd /; rm -rf "$d"
