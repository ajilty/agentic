# reground's READ-ONLY branch (ADR-0014). Previously this branch (ledger.sh) printed
# a generic "re-dispatch if artifact absent" line WITHOUT ever checking disk — it was
# the one re-dispatch decision with NO test. With the disk-first read lane the result
# is a durable file, so reground must key the re-dispatch decision on its presence:
#   findings/<slug>.md ABSENT  -> open lane, re-dispatch (no result on disk)
#   findings/<slug>.md PRESENT -> satisfied, do not re-dispatch
# A read-only lane is NEVER an ambiguous-writer HALT (exit 0 either way).
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"

# a dispatched researcher whose result file does NOT yet exist -> open, re-dispatch
bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"researcher","slug":"auth-flow"}'
out="$(bash "$R" reground 2>&1)"; code=$?
assert_eq "$code" "0" "read-only open lane is not a writer HALT"
case "$out" in *"no result on disk"*) pass;; *) fail "reground flags the missing read-only result for re-dispatch";; esac

# once the promoted findings file exists, the lane is satisfied (no re-dispatch)
mkdir -p ".agents/runs/orchestrate/tickets/T1/findings"
echo "# findings" > ".agents/runs/orchestrate/tickets/T1/findings/auth-flow.md"
out="$(bash "$R" reground 2>&1)"; code=$?
assert_eq "$code" "0" "read-only satisfied lane is clean"
case "$out" in *"no result on disk"*) fail "reground still asks to re-dispatch a satisfied read-only lane";; *) pass;; esac
case "$out" in *"result on disk"*) pass;; *) fail "reground reports the read-only result is present";; esac

cd /; rm -rf "$d"

# --- in-flight writer with no branch on its dispatched event (native worktree
#     isolation: the harness names the worktree, the branch lands on returned):
#     reground must HALT (exit 3), never offer a re-dispatch.
r="$(mktemp_repo)"
( cd "$r" && git commit -qm init --allow-empty && bash "$HERE/../skills/orchestrate/runtime/ledger.sh" append '{"ticket":"W1","event":"dispatched","persona":"implementer","dispatch_id":"d1"}' >/dev/null 2>&1 )
out="$(cd "$r" && bash "$HERE/../skills/orchestrate/runtime/ledger.sh" reground 2>&1)"; rc=$?
assert_eq "$rc" "3" "reground: implementer dispatched with unknown branch HALTs"
case "$out" in *"branch=unknown"*) pass;; *) fail "reground names the unknown-branch writer lane";; esac
rm -rf "$r"
