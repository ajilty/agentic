# 2026-08-05 wave-2 review gaps: (1) hook telemetry appended to a linked worktree's
# COPY of board.jsonl left the tree permanently dirty after merge, and reground then
# HALTed on "ambiguous in-flight writer" for lanes that were done (4 false HALTs).
# Fixes under test: ledger.sh anchors the board at the MAIN checkout root from any
# worktree cwd; reground classifies board.jsonl-only dirt as residue (no HALT) while
# real work in a lane worktree the board lost still fails closed; other sessions'
# worktrees are counted, never judged (0.9.0 scope).
R="$HERE/../skills/orchestrate/runtime"
d="$(mktemp -d)"; ( cd "$d" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p .agents/runs/orchestrate && echo '{"event":"goal","note":"g"}' > .agents/runs/orchestrate/board.jsonl
  git add -A && git commit -qm init
  git worktree add -q -b worktree-agent-T1-implementer .agents/worktrees/T1-implementer HEAD )
wt="$d/.agents/worktrees/T1-implementer"

# 1) append from INSIDE the worktree lands in the ROOT board; worktree stays clean
( cd "$wt" && bash "$R/ledger.sh" append '{"event":"denied","hook":"keep-on-branch","note":"t"}' >/dev/null 2>&1 )
grep -q '"event":"denied"' "$d/.agents/runs/orchestrate/board.jsonl" && pass || fail "worktree append lands in root board"
[ -z "$(git -C "$wt" status --porcelain)" ] && pass || fail "worktree stays clean after telemetry append"

# 2) legacy residue (board.jsonl-only dirt in the worktree copy): reground reports, no HALT
echo '{"event":"denied","note":"legacy"}' >> "$wt/.agents/runs/orchestrate/board.jsonl"
out="$(cd "$d" && bash "$R/ledger.sh" reground)"; rc=$?
assert_eq "$rc" 0 "board.jsonl-only dirt does not HALT reground"
case "$out" in *"TELEMETRY RESIDUE"*) pass;; *) fail "reground names the residue ($out)";; esac

# 3) real uncommitted work (even alongside residue) in a tree that is NOT this run's lane:
#    another session's worktree, counted once and never judged (no HALT)
echo x >> "$wt/real-work.txt"
out="$(cd "$d" && bash "$R/ledger.sh" reground 2>&1)"; rc=$?
assert_eq "$rc" 0 "another session's dirty worktree does not HALT reground"
case "$out" in *"OTHER WORKTREES (not this run): 1"*) pass;; *) fail "reground counts the other worktree ($out)";; esac
case "$out" in *"DIRTY WORKTREE"*) fail "reground must not judge another session's worktree ($out)";; *) pass;; esac

# 3b) the same tree once its branch names a board ticket with no dispatched row: a lane
#     the ledger lost -> HALT (exit 3)
( cd "$d" && bash "$R/ledger.sh" append '{"ticket":"T1","event":"intake","tier":"T1"}' >/dev/null 2>&1 )
out="$(cd "$d" && bash "$R/ledger.sh" reground 2>&1)"; rc=$?
assert_eq "$rc" 3 "lost lane (dirty, no dispatched row) HALTs reground"
case "$out" in *"DIRTY WORKTREE"*"ticket=T1"*"no dispatched row"*) pass;; *) fail "reground names the lost lane ($out)";; esac

# 3c) with a dispatched row it is a writer in flight or crashed: reported, no HALT
( cd "$d" && bash "$R/ledger.sh" append '{"ticket":"T1","event":"dispatched","persona":"implementer","dispatch_id":"d1"}' >/dev/null 2>&1 )
out="$(cd "$d" && bash "$R/ledger.sh" reground 2>&1)"; rc=$?
assert_eq "$rc" 0 "dispatched lane's dirty worktree does not HALT"
case "$out" in *"DIRTY WORKTREE"*"ticket=T1"*"in flight or crashed; confirm before re-dispatch"*) pass;; *) fail "reground reports the in-flight dirty lane ($out)";; esac

# 4) a worktree whose branch a returned row names is this run's lane wherever it lives;
#    a Claude Code session worktree (worktree-<name>) that no row names is not
git -C "$d" worktree add -q -b worktree-native .claude/worktrees/native HEAD 2>/dev/null
rm -f "$wt/real-work.txt"; git -C "$wt" checkout -q -- . 2>/dev/null
echo y > "$d/.claude/worktrees/native/work.txt"
out="$(cd "$d" && bash "$R/ledger.sh" reground 2>&1)"; rc=$?
assert_eq "$rc" 0 "a dirty session worktree (worktree-<name>) the board never names does not HALT"
case "$out" in *"OTHER WORKTREES (not this run): 1"*) pass;; *) fail "session worktree counted as other ($out)";; esac
( cd "$d" && bash "$R/ledger.sh" append '{"ticket":"T2","event":"dispatched","persona":"implementer","dispatch_id":"d2"}' >/dev/null 2>&1
  bash "$R/ledger.sh" append '{"ticket":"T2","event":"returned","persona":"implementer","status":"DONE","branch":"worktree-native"}' >/dev/null 2>&1 )
out="$(cd "$d" && bash "$R/ledger.sh" reground 2>&1)"; rc=$?
case "$out" in *"DIRTY WORKTREE"*"worktree-native"*"ticket=T2"*) pass;; *) fail "returned-row branch makes the tree a lane ($out)";; esac
case "$out" in *"OPEN LANE     ticket=T2 last=returned"*) pass;; *) fail "returned lane listed as awaiting its verdict ($out)";; esac

rm -rf "$d"
