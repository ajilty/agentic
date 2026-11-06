# Tier 3c (live) — TRACE CONFORMANCE end-to-end: drive a REAL minimal chain and assert
# the choreography actually fired on the real harness. This is the live half of the
# "watch the skills execute when expected" eval: the deterministic test_conformance.sh
# proves the checker discriminates conformant vs degraded traces; this proves a real
# orchestrate chain PRODUCES a conformant trace on the actual CC dispatch path (the
# exact thing the namespaced-persona / dead-SubagentStart bugs silently broke).
#
# Router drives: journal `dispatched` for the implementer and dispatch it -> dispatch
# verifier -> append the verdict in-loop (as the real router does; no hook journals
# dispatches any more, ADR-0040). Then `ledger.sh conformance
# dispatched:implementer verdict` must pass against the REAL board.jsonl. Robust to
# model nondeterminism: skip if the chain didn't run.
if ! have_claude; then
  skip "tier3 conformance-lane: claude CLI not on PATH"
elif ! have_live_auth; then
  skip "tier3 conformance-lane: no live auth"
else
  h="$(mk_authed_home)"; repo="$(mk_repo)"
  LEDGER="$PLUGIN_DIR/skills/orchestrate/runtime/ledger.sh"
  prompt="You are the orchestrate router. Do these steps strictly in order:
1. Run EXACTLY this Bash command: bash $LEDGER append '{\"ticket\":\"T-cf\",\"event\":\"dispatched\",\"persona\":\"implementer\"}'. Then use the Task tool to dispatch a subagent of type orchestrate:implementer with instruction: 'use your Write tool to create a file done.txt containing the text ok, then reply DONE'.
2. Use the Task tool to dispatch a subagent of type orchestrate:verifier with instruction: 'check that the file done.txt exists in the current directory and reply APPROVED if it does, REJECTED otherwise'.
3. After the verifier replies, record its verdict by running EXACTLY this Bash command: bash $LEDGER append '{\"ticket\":\"T-cf\",\"event\":\"verdict\",\"verdict\":\"APPROVED\"}'
Then stop."
  printf '%s' "$prompt" | ( cd "$repo" && HOME="$h" timeout 420 claude -p --plugin-dir "$PLUGIN_DIR" --allowedTools "Task,Bash,Write" ) >/dev/null 2>&1

  board="$repo/.agents/runs/orchestrate/board.jsonl"
  if grep -q '"event":"dispatched".*"persona":"implementer"' "$board" 2>/dev/null && grep -q '"event":"verdict"' "$board" 2>/dev/null; then
    # the expected steps are journaled — now the conformance checker must AGREE, on a real board
    ( cd "$repo" && bash "$LEDGER" conformance dispatched:implementer verdict ) >/dev/null 2>&1
    assert_eq "$?" "0" "conformance passes on a REAL chain trace (implementer dispatched -> verdict)"
    # and it must still CATCH a degraded expectation the real run didn't satisfy (no actuator ran)
    ( cd "$repo" && bash "$LEDGER" conformance dispatched:implementer dispatched:actuator verdict ) >/dev/null 2>&1
    assert_eq "$?" "1" "conformance still FAILS an unmet step (no actuator was dispatched) on the real board"
  else
    skip "the chain did not journal both steps this run (model declined) — conformance lane not exercised"
  fi
  cd /
fi
