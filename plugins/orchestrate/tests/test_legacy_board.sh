# A 0.8.x board (lease-conflict, gate-blocked, goal.model_policy rows) must still read:
# `metrics` and `reground` do not warn or fail; the old vocabulary is read, never written.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"
B=".agents/runs/orchestrate/board.jsonl"
cat > "$B" <<'JSONL'
{"ts":"2026-08-01T00:00:00Z","event":"goal","note":"old run","spec":"docs/plan.md","base":"main","model_policy":"quick"}
{"ts":"2026-08-01T00:00:01Z","ticket":"T1","event":"intake","tier":"T1"}
{"ts":"2026-08-01T00:00:02Z","ticket":"T1","event":"dispatched","persona":"implementer","branch":"worktree-agent-T1-implementer"}
{"ts":"2026-08-01T00:00:03Z","ticket":"T1","event":"lease-conflict","persona":"actuator","key":"db"}
{"ts":"2026-08-01T00:00:04Z","ticket":"T1","event":"gate-blocked","persona":"actuator","note":"prod"}
{"ts":"2026-08-01T00:00:05Z","ticket":"T1","event":"verdict","verdict":"APPROVED"}
{"ts":"2026-08-01T00:00:06Z","ticket":"T1","event":"done"}
JSONL
out="$(bash "$R" metrics 2>&1)"; rc=$?
assert_eq "$rc" "0" "metrics exits 0 on a 0.8.x board"
case "$out" in *shipped=1*) pass;; *) fail "metrics counts the legacy done row ($out)";; esac
case "$out" in *[Ww]arning*) fail "metrics does not warn on legacy rows ($out)";; *) pass;; esac
out="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "reground exits 0 on a 0.8.x board"
case "$out" in *"GOAL: old run"*) pass;; *) fail "reground prints the legacy goal ($out)";; esac
case "$out" in *"models:"*) fail "reground no longer surfaces the dropped 0.8.x model policy ($out)";; *) pass;; esac
case "$out" in *[Ww]arning*) fail "reground does not warn on legacy rows ($out)";; *) pass;; esac
cd /; rm -rf "$d"
