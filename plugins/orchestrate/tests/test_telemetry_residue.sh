# 2026-08-05 wave-2 review gaps: (1) hook telemetry appended to a linked worktree's
# COPY of board.jsonl left the tree permanently dirty after merge, and reground then
# HALTed on "ambiguous in-flight writer" for lanes that were done (4 false HALTs).
# Fixes under test: ledger.sh anchors the board at the MAIN checkout root from any
# worktree cwd; reground classifies board.jsonl-only dirt as residue (no HALT) while
# real work still fails closed (worktree-* and worktree-agent-* branches both count).
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

# 3) real uncommitted work (even alongside residue) still fails closed
echo x >> "$wt/real-work.txt"
( cd "$d" && bash "$R/ledger.sh" reground >/dev/null 2>&1 ); rc=$?
assert_eq "$rc" 3 "real uncommitted work still HALTs reground"

# 4) the harness's native worktree branch names (worktree-<name>) are watched too
git -C "$d" worktree add -q -b worktree-native .agents/worktrees/native HEAD 2>/dev/null
rm -f "$wt/real-work.txt"; git -C "$wt" checkout -q -- . 2>/dev/null
echo y > "$d/.agents/worktrees/native/work.txt"
out="$(cd "$d" && bash "$R/ledger.sh" reground)"; rc=$?
assert_eq "$rc" 3 "dirty worktree-* branch HALTs reground"
case "$out" in *"DIRTY WORKTREE"*"worktree-native"*) pass;; *) fail "reground names the native worktree ($out)";; esac

rm -rf "$d"
