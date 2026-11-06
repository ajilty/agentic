# Tier 3c, Layer 3 — ledger-derived §8 metrics + the durable feedback record
# (deterministic, no live model). Backs the /orchestrate:feedback command.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"

# Plant a board with a representative mix of events (model/effort are OPTIONAL on
# dispatched — journaled horsepower for right-sizing verification).
bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"implementer","model":"sonnet","effort":"high"}'
bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"verifier","model":"opus","effort":"max"}'
bash "$R" append '{"ticket":"T2","event":"dispatched","persona":"researcher"}'
bash "$R" append '{"ticket":"T1","event":"verdict","verdict":"REJECTED"}'
bash "$R" append '{"ticket":"T1","event":"verdict","verdict":"APPROVED"}'
bash "$R" append '{"ticket":"T1","event":"done"}'
bash "$R" append '{"ticket":"T2","event":"fork","state":"halted","fork_id":"F1"}'
bash "$R" append '{"ticket":"T2","event":"decision","fork_id":"F1","adr":"0099"}'
# legacy 0.8.x row, read but no longer written (so it is added raw, not via append)
printf '%s\n' '{"ts":"2026-08-01T00:00:00Z","ticket":"T2","event":"lease-conflict","persona":"actuator","key":"db"}' >> .agents/runs/orchestrate/board.jsonl
bash "$R" append '{"event":"denied","hook":"run-scope","persona":"verifier","note":"git checkout -- x"}'

m="$(bash "$R" metrics)"
case "$m" in *"shipped=1"*)   pass;; *) fail "metrics shipped=1 ($m)";; esac
case "$m" in *"rejects=1"*)   pass;; *) fail "metrics rejects=1 ($m)";; esac
case "$m" in *"forks=1"*)     pass;; *) fail "metrics forks=1 ($m)";; esac
case "$m" in *"decisions=1"*) pass;; *) fail "metrics decisions=1 ($m)";; esac
# friction = rejects(1) + oracle_inconsistent(0) + lease_conflicts(1) = 2
case "$m" in *"friction=2"*)  pass;; *) fail "metrics friction=2 ($m)";; esac
# denials (ADR-0032): hook-journaled enforcement refusals, counted separately
case "$m" in *"denials=1"*)   pass;; *) fail "metrics denials=1 ($m)";; esac
# model_mix: journaled horsepower per persona (persona:model:effort:count; '-' when absent)
case "$m" in *"implementer:sonnet:high:1"*) pass;; *) fail "model_mix carries implementer:sonnet:high:1 ($m)";; esac
case "$m" in *"verifier:opus:max:1"*)       pass;; *) fail "model_mix carries verifier:opus:max:1 ($m)";; esac
case "$m" in *"researcher:-:-:1"*)          pass;; *) fail "model_mix marks missing model/effort as '-' ($m)";; esac
# ticket filter narrows the replay
mt="$(bash "$R" metrics T2)"
case "$mt" in *"shipped=0"*"forks=1"*) pass;; *) fail "metrics ticket-filter ($mt)";; esac

# feedback appends a durable record embedding the snapshot + the operator note
bash "$R" feedback "smooth run, one healthy fork" >/dev/null
FB=".agents/runs/orchestrate/eval/feedback.jsonl"
assert_file "$FB"
grep -q '"event":"feedback"' "$FB"        && pass || fail "feedback record written"
grep -q '"shipped":1'        "$FB"        && pass || fail "feedback embeds metrics snapshot"
grep -q 'smooth run, one healthy fork' "$FB" && pass || fail "feedback embeds the operator note"
grep -q '"model_mix":"' "$FB"             && pass || fail "feedback embeds model_mix (quoted string)"
grep -qE '"plugin_version":"[0-9]' "$FB"  && pass || fail "feedback stamped with the plugin version (ADR-0028)"
# the record must be VALID JSON: non-integer metric values (verify_coverage=1/2,
# model_mix=...) are quoted; previously they'd have emitted bare 1/2 (invalid)
if command -v python3 >/dev/null 2>&1; then
  tail -1 "$FB" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null && pass || fail "feedback record is valid JSON"
fi

# EMPTY board (regression): metrics + feedback must work before any dispatch — grep's
# exit-1 on zero dispatched events killed both under pipefail (latent since model_mix).
d2="$(mktemp_repo)"; cd "$d2"
me="$(bash "$R" metrics)"; rc=$?
assert_eq "$rc" "0" "metrics exits 0 on an EMPTY board"
case "$me" in *"model_mix=-"*) pass;; *) fail "empty-board model_mix is '-' ($me)";; esac
bash "$R" feedback "early feedback, nothing dispatched yet" >/dev/null 2>&1
assert_eq "$?" "0" "feedback exits 0 on an EMPTY board"
assert_file ".agents/runs/orchestrate/eval/feedback.jsonl"
cd /; rm -rf "$d2"

cd /; rm -rf "$d"
