RT="$HERE/../skills/orchestrate/runtime"
GATE="$RT/hooks/gate-prod-apply.sh"
d="$(mktemp_repo)"; cd "$d"
# a prod-level target with no operator ack -> gate DENIES (exit 2, CC block) + journals gate-blocked
PERSONA=actuator TICKET=T1 PROD_TARGETS='tfstate:prod/net' bash "$GATE" >/dev/null 2>&1
rc=$?; assert_eq "$rc" "2" "unacked prod target -> gate denies dispatch (exit 2)"
grep -q '"event":"gate-blocked".*"key":"tfstate:prod/net"' .agents/runs/orchestrate/board.jsonl && pass || fail "gate-blocked journaled"
# after the operator acks -> gate ALLOWS (exit 0)
bash "$RT/ledger.sh" ack T1 'tfstate:prod/net'
PERSONA=actuator TICKET=T1 PROD_TARGETS='tfstate:prod/net' bash "$GATE" >/dev/null 2>&1
assert_eq "$?" "0" "acked prod target -> gate allows"
# registered via env with no prod targets declared -> allow
PERSONA=actuator TICKET=T2 PROD_TARGETS= bash "$GATE" >/dev/null 2>&1
assert_eq "$?" "0" "no prod targets -> gate allows"
# a lone TICKET env (no PROD_TARGETS, no record) is not registration -> deny
PERSONA=actuator TICKET=JIRA-1 bash "$GATE" >/dev/null 2>&1
assert_eq "$?" "2" "TICKET env without PROD_TARGETS does not arm an empty target list"
# non-actuator persona -> no-op allow
PERSONA=researcher TICKET=T3 PROD_TARGETS='tfstate:prod/net' bash "$GATE" >/dev/null 2>&1
assert_eq "$?" "0" "non-actuator -> gate no-op"
cd /; rm -rf "$d"

# write-ahead must leave NO trace when a prod target is unacked (no false
# dispatched/lease that would poison the next reground) — SubagentStart can't
# block the dispatch, but it must not lie about it.
WA="$RT/hooks/on-writer-dispatch.sh"
d2="$(mktemp_repo)"; cd "$d2"
PERSONA=actuator TICKET=TA PROD_TARGETS='tfstate:prod/x' TARGETS='tfstate:prod/x' DISPATCH_ID=z bash "$WA" >/dev/null 2>&1
grep -q '"event":"dispatched"' .agents/runs/orchestrate/board.jsonl && fail "unacked actuator must NOT journal dispatched" || pass
assert_no_file ".agents/runs/orchestrate/leases/tfstate:prod%2Fx"
grep -q '"event":"gate-blocked"' .agents/runs/orchestrate/board.jsonl && pass || fail "unacked actuator journals gate-blocked"
# after operator ack -> normal write-ahead (dispatched + lease)
bash "$RT/ledger.sh" ack TA 'tfstate:prod/x'
PERSONA=actuator TICKET=TA PROD_TARGETS='tfstate:prod/x' TARGETS='tfstate:prod/x' DISPATCH_ID=z2 bash "$WA" >/dev/null 2>&1
grep -q '"event":"dispatched".*"persona":"actuator"' .agents/runs/orchestrate/board.jsonl && pass || fail "acked actuator journals dispatched"
assert_file ".agents/runs/orchestrate/leases/tfstate:prod%2Fx"
cd /; rm -rf "$d2"
