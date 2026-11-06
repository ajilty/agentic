RT="$HERE/../skills/orchestrate/runtime"
GATE="$RT/hooks/gate-prod-apply.sh"
KOB="$RT/hooks/keep-on-branch.sh"
WA="$RT/hooks/on-writer-dispatch.sh"
d="$(mktemp_repo)"; cd "$d"
AW=".agents/runs/orchestrate"

# --- ledger writer-ctx set/get/clear roundtrip (ADR-0006 on-disk bridge, per persona ADR-0039) ---
bash "$RT/ledger.sh" writer-ctx set T7 actuator "" 'tfstate:prod/db k8s:stg/app'
assert_file "$AW/active-writer.actuator.json"
assert_no_file "$AW/active-writer.json"
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator ticket)" "T7" "writer-ctx get ticket"
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator persona)" "actuator" "writer-ctx get persona"
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator prod_targets)" "tfstate:prod/db k8s:stg/app" "writer-ctx get prod_targets"
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get implementer ticket)" "" "another persona's record is not visible"
bash "$RT/ledger.sh" writer-ctx get ticket >/dev/null 2>&1; rc=$?
assert_eq "$rc" "64" "writer-ctx get without a persona is a usage error"
bash "$RT/ledger.sh" writer-ctx clear actuator
assert_no_file "$AW/active-writer.actuator.json"

# --- gate ENFORCES from the actuator record with NO per-dispatch env (the CC scenario) ---
bash "$RT/ledger.sh" writer-ctx set T7 actuator "" 'tfstate:prod/db'
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?   # no TICKET/PROD_TARGETS env -> reads record
assert_eq "$rc" "2" "gate denies from active-writer record (unacked prod target, no env)"
grep -q '"event":"gate-blocked".*"key":"tfstate:prod/db"' "$AW/board.jsonl" && pass || fail "gate-blocked journaled via record path"
bash "$RT/ledger.sh" ack T7 'tfstate:prod/db'
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "gate allows from record after operator ack"

# --- a builder registering or closing does NOT touch the actuator's gate context ---
bash "$RT/ledger.sh" writer-ctx set T8 implementer worktree-agent-T8-impl
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator ticket)" "T7" "builder set leaves the actuator record intact"
bash "$RT/ledger.sh" writer-ctx set T7b actuator "" 'tfstate:prod/other'
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "a new unacked actuator record is enforced"
bash "$RT/ledger.sh" writer-ctx clear implementer
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator ticket)" "T7b" "builder clear leaves the actuator record intact"
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "gate still denies after a builder lane closed"

# --- gate FAILS CLOSED when the actuator has no record at all (no env either) ---
bash "$RT/ledger.sh" writer-ctx clear actuator
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "no actuator record and no env -> gate denies (fail closed)"
grep -q '"event":"gate-blocked".*"key":"unregistered"' "$AW/board.jsonl" && pass || fail "unregistered actuator journals gate-blocked key=unregistered"
# a builder record is not an actuator context either
bash "$RT/ledger.sh" writer-ctx set T8 implementer worktree-agent-T8-impl
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "a builder record does not stand in for the actuator's"
# a registered actuator with NO prod targets (declared safe) is allowed
bash "$RT/ledger.sh" writer-ctx set T7c actuator ""
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "registered actuator with no prod targets -> allow"
# the legacy single-slot file is never read as context
bash "$RT/ledger.sh" writer-ctx clear actuator
printf 'ticket=OLD\npersona=actuator\nassigned_branch=\nprod_targets=\nts=x\n' > "$AW/active-writer.json"
PERSONA=actuator bash "$GATE" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "legacy active-writer.json does not arm the gate"
rm -f "$AW/active-writer.json"

# --- branch-guard reads assigned_branch from the implementer record (no env) ---
PERSONA=implementer TOOL_INPUT='git commit -m x' bash "$KOB" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "keep-on-branch denies off-assigned-branch commit from record"
bash "$RT/ledger.sh" writer-ctx set T7d actuator "" 'tfstate:prod/x'
PERSONA=implementer TOOL_INPUT='git commit -m x' bash "$KOB" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "an actuator record does not change the builder's assigned branch"
bash "$RT/ledger.sh" writer-ctx clear implementer
PERSONA=implementer TOOL_INPUT='git commit -m x' bash "$KOB" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "no implementer record -> branch check is skipped (unchanged behavior)"
bash "$RT/ledger.sh" writer-ctx clear

# --- write-ahead attributes each writer to its own persona's record (own repo: it journals open lanes) ---
command -v jq >/dev/null 2>&1 && {
  d2="$(mktemp_repo)"; cd "$d2"
  bash "$RT/ledger.sh" writer-ctx set TB implementer worktree-agent-TB-impl
  bash "$RT/ledger.sh" writer-ctx set TC actuator "" 'tfstate:prod/c'
  bash "$RT/ledger.sh" ack TC 'tfstate:prod/c'
  printf '{"tool_input":{"subagent_type":"orchestrate:actuator"}}' | bash "$WA" >/dev/null 2>&1
  grep -q '"ticket":"TC","event":"dispatched","persona":"actuator"' "$AW/board.jsonl" && pass || fail "actuator write-ahead journals under the actuator record's ticket"
  grep -q '"ticket":"TB","event":"dispatched","persona":"actuator"' "$AW/board.jsonl" && fail "actuator write-ahead must not use the builder's ticket" || pass
  printf '{"tool_input":{"subagent_type":"orchestrate:implementer"}}' | bash "$WA" >/dev/null 2>&1
  grep -q '"ticket":"TB","event":"dispatched","persona":"implementer","branch":"worktree-agent-TB-impl"' "$AW/board.jsonl" && pass || fail "implementer write-ahead journals under the implementer record's ticket and branch"
  cd "$d"; rm -rf "$d2"
}

# --- writer-ctx set OVERWRITES the prior record of the SAME persona (the per-dispatch refresh) ---
bash "$RT/ledger.sh" writer-ctx set TA actuator "" 'a:1'
bash "$RT/ledger.sh" writer-ctx set TB actuator "" 'b:2'
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator ticket)" "TB" "writer-ctx set overwrites prior record (ticket)"
assert_eq "$(bash "$RT/ledger.sh" writer-ctx get actuator prod_targets)" "b:2" "writer-ctx set overwrites prior record (targets)"
bash "$RT/ledger.sh" writer-ctx clear

# --- bare clear removes every persona record and the legacy file ---
bash "$RT/ledger.sh" writer-ctx set TA actuator "" 'a:1'
bash "$RT/ledger.sh" writer-ctx set TB implementer br
: > "$AW/active-writer.json"
bash "$RT/ledger.sh" writer-ctx clear
assert_no_file "$AW/active-writer.actuator.json"
assert_no_file "$AW/active-writer.implementer.json"
assert_no_file "$AW/active-writer.json"

# --- reground HALTs on a dangling record of either persona, and on the legacy file ---
bash "$RT/ledger.sh" writer-ctx set TZ actuator "" 'tfstate:prod/x'
out="$(bash "$RT/ledger.sh" reground 2>&1)"; code=$?
assert_eq "$code" "3" "dangling actuator record -> reground HALT (exit 3)"
case "$out" in *"active-writer ticket=TZ persona=actuator"*) pass;; *) fail "reground names the dangling actuator record (got: $out)";; esac
bash "$RT/ledger.sh" writer-ctx set TY implementer br
out="$(bash "$RT/ledger.sh" reground 2>&1)"
case "$out" in *"ticket=TY persona=implementer"*) pass;; *) fail "reground names the dangling implementer record too (got: $out)";; esac
bash "$RT/ledger.sh" writer-ctx clear
out="$(bash "$RT/ledger.sh" reground 2>&1)"; code=$?
assert_eq "$code" "0" "after writer-ctx clear -> reground clean (exit 0)"
# an empty/malformed record still HALTs (set -e safe; existence drives it)
: > "$AW/active-writer.implementer.json"
out="$(bash "$RT/ledger.sh" reground 2>&1)"; code=$?
assert_eq "$code" "3" "empty per-persona record still HALTs (set -e safe)"
rm -f "$AW/active-writer.implementer.json"
# a leftover legacy single-slot file from an older plugin HALTs and is named as legacy
printf 'ticket=OLD\npersona=implementer\n' > "$AW/active-writer.json"
out="$(bash "$RT/ledger.sh" reground 2>&1)"; code=$?
assert_eq "$code" "3" "legacy active-writer.json -> reground HALT (exit 3)"
case "$out" in *"legacy"*"ticket=OLD"*) pass;; *) fail "reground names the legacy record (got: $out)";; esac
rm -f "$AW/active-writer.json"
cd /; rm -rf "$d"
