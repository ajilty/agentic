# Lane copies go when the lane's work has ended, and only then. `ledger.sh retire` removes a
# worktree only when a board row names its branch exactly, its lane is not in flight, and
# either everything the branch holds is already on the base (judged by content) or the board
# says a later round replaced it. It keeps anything holding a file, never unlocks, and never
# judges a tree by its name. `ledger.sh result` puts a writer's handback in the primary
# checkout and removes the writer's copy only once the stored one is proven equal. Reground
# counts the copies and changes nothing.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"; d="$(pwd -P)"; git checkout -q -b main 2>/dev/null || git branch -m main
echo base > f.txt; printf '*.plan\n' > .gitignore; git add f.txt .gitignore; git commit -qm init
bash "$R" goal "retire test" "" main >/dev/null
W="$d/.claude/worktrees"
tree(){ git worktree add -q -b "$1" "$W/$2" main; ( cd "$W/$2" && echo "$1" > "$2.txt" && git add "$2.txt" && git commit -qm "work on $2" ); }
row(){ bash "$R" append "$1"; }
lane(){ # <ticket> <branch> <dir> [extra dispatched fields]: a writer's tree with one commit, journaled as returned
  tree "$2" "$3"
  row "{\"ticket\":\"$1\",\"event\":\"dispatched\",\"persona\":\"implementer\",\"dispatch_id\":\"$3\",\"branch\":\"$2\"${4:+,$4}}"
  row "{\"ticket\":\"$1\",\"event\":\"returned\",\"persona\":\"implementer\",\"status\":\"DONE\",\"branch\":\"$2\"}"
}
squash(){ git merge -q --squash "$1" >/dev/null && git commit -qm "$1 squashed"; }   # the base takes the branch as one commit
has(){ case "$out" in *"$1"*) pass ;; *) fail "$2 (got: $out)" ;; esac; }
hasnt(){ case "$out" in *"$1"*) fail "$2 (got: $out)" ;; *) pass ;; esac; }
here(){ [ -d "$W/$1" ] && pass || fail "$2"; }
gone(){ [ ! -e "$W/$1" ] && pass || fail "$2"; }

lane L1 orchestrate/L1 a1; squash orchestrate/L1                       # landed by squash, lane still open
lane L2 orchestrate/L2 a2                                              # pull request still open
lane L3 orchestrate/L3 a3                                              # round 1, never landed
lane L3 orchestrate/L3-r2 a3r2 '"replaces":"orchestrate/L3"'; squash orchestrate/L3-r2; bash "$R" done L3 2>/dev/null
lane P orchestrate/P-t1 p1; lane P orchestrate/P-t2 p2; bash "$R" done P 2>/dev/null   # two tasks of one closed ticket, neither merged
lane L4 orchestrate/L4 a4; squash orchestrate/L4; echo note > "$W/a4/left.txt"          # landed, an untracked file left in it
lane L4i orchestrate/L4i a4i; squash orchestrate/L4i; echo saved > "$W/a4i/prod.plan"   # landed, an ignored file left in it
tree orchestrate/L5 a5; squash orchestrate/L5                                           # landed, but its lane is in flight
row '{"ticket":"L5","event":"dispatched","persona":"implementer","dispatch_id":"a5","branch":"orchestrate/L5"}'
lane L6 orchestrate/L6 a6; squash orchestrate/L6; git worktree lock --reason "claude agent a6 (pid 1)" "$W/a6"
lane L7 orchestrate/L7 a7; bash "$R" done L7 2>/dev/null                                # closed, not landed, nothing replaces it: handed over
git worktree add -q -b orchestrate/L10 "$W/a10" main                                    # returned with no commit, lane open
row '{"ticket":"L10","event":"returned","persona":"implementer","status":"BLOCKED","branch":"orchestrate/L10"}'
lane L12 orchestrate/L12 a12; squash orchestrate/L12                                    # landed, then one more commit nobody merged
( cd "$W/a12" && echo more > more.txt && git add more.txt && git commit -qm "follow-up" )
# Names that only look like this run's: a closed ticket "fix" beside an open "fix-2" whose row names no
# branch, that ticket's hand-made apply copy, a session the operator opened, and a branch two tickets name.
row '{"ticket":"fix","event":"intake","tier":"T1"}'; bash "$R" done fix 2>/dev/null
row '{"ticket":"fix-2","event":"dispatched","persona":"implementer","dispatch_id":"x2"}'
tree orchestrate/fix-2 fix-2; row '{"ticket":"fix-2","event":"returned","persona":"implementer","status":"DONE"}'
git worktree add -q --detach "$d/.agents/worktrees/fix-2-apply" main; echo saved > "$d/.agents/worktrees/fix-2-apply/prod.plan"
git worktree add -q -b worktree-fix-refactor "$W/fix-refactor" main
lane T1 orchestrate/shared sh; row '{"ticket":"T2","event":"returned","persona":"implementer","status":"DONE","branch":"orchestrate/shared"}'
squash orchestrate/shared; bash "$R" done T1 2>/dev/null; bash "$R" done T2 2>/dev/null
# A result left in a tree by an older version: carried home when the primary lacks it, left when the primary's differs.
lane L13 orchestrate/L13 a13; squash orchestrate/L13
mkdir -p "$W/a13/.agents/runs/orchestrate/tickets/L13/results"; printf 'only copy\n' > "$W/a13/.agents/runs/orchestrate/tickets/L13/results/d13.md"
lane L14 orchestrate/L14 a14; squash orchestrate/L14
mkdir -p "$W/a14/.agents/runs/orchestrate/tickets/L14/results" "$d/.agents/runs/orchestrate/tickets/L14/results"
echo theirs > "$W/a14/.agents/runs/orchestrate/tickets/L14/results/d14.md"; echo ours > "$d/.agents/runs/orchestrate/tickets/L14/results/d14.md"

# Reground counts the copies a board row names, points at retire, and changes nothing.
before="$(git worktree list | wc -l | tr -d ' ')"
out="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "lane copies on disk are a report, not a halt"
has "LANE WORKTREES ON DISK: " "reground counts the copies of lanes no longer in flight"
has "-> run: ledger.sh retire" "and points at retire"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "$before" "reground removes nothing"

# A dry run says what would go and what it would carry home, and changes nothing.
out="$(bash "$R" retire --dry-run 2>&1)"
has "WOULD RETIRE $W/a1 (orchestrate/L1) ticket=L1 landed" "a dry run names a landed lane's tree"
has "WOULD CARRY HOME .agents/runs/orchestrate/tickets/L13/results/d13.md" "a dry run names a result it would carry home"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "$before" "a dry run removes nothing"
[ -f "$W/a13/.agents/runs/orchestrate/tickets/L13/results/d13.md" ] && [ ! -e "$d/.agents/runs/orchestrate/tickets/L13/results/d13.md" ] && pass || fail "a dry run carries nothing"

out="$(bash "$R" retire 2>&1)"
has "RETIRED $W/a1 (orchestrate/L1) ticket=L1 landed" "a squash-landed lane's tree is removed"
gone a1 "a landed lane's tree is gone"; git rev-parse -q --verify orchestrate/L1 >/dev/null && fail "a landed lane's branch is deleted" || pass
here a2 "an open lane whose change has not landed keeps its tree"; hasnt "$W/a2 " "and is not mentioned"
has "RETIRED $W/a3 (orchestrate/L3) ticket=L3 replaced; branch kept" "a round the board says was replaced loses its tree"
gone a3 "the replaced round's tree is gone"; git rev-parse -q --verify orchestrate/L3 >/dev/null && pass || fail "a replaced round keeps its branch"
gone a3r2 "the round that landed is removed too"
here p1 "a closed ticket's unmerged task keeps its tree"; here p2 "and so does its other task: neither replaces the other"
hasnt "$W/p1 " "parallel tasks of a closed ticket are not mentioned"
has "KEPT    $W/a4 (orchestrate/L4) ticket=L4 landed -> it holds files: ?? left.txt;" "a landed tree with an untracked file is kept and the file named"
[ -f "$W/a4/left.txt" ] && pass || fail "an untracked file is never removed"
has "KEPT    $W/a4i (orchestrate/L4i) ticket=L4i landed -> it holds files: ?? prod.plan;" "a landed tree with an ignored file is kept and the file named"
[ -f "$W/a4i/prod.plan" ] && pass || fail "an ignored file is never removed"
here a5 "an in-flight lane keeps its tree even when its change is on the base"; hasnt "$W/a5 " "and is not mentioned"
has "KEPT    $W/a6 (orchestrate/L6) ticket=L6 landed -> locked claude agent a6 (pid 1): retire never unlocks" "a locked tree is kept and its lock named"
here a6 "a locked tree stays"; [ -f "$d/.git/worktrees/a6/locked" ] && pass || fail "the lock is still in place"
here a7 "a handed-over lane keeps its tree"; hasnt "$W/a7 " "and is not mentioned"
here a10 "a tree with no commits stays while its lane is open"
here a12 "a landed lane with a later commit keeps its tree"; git rev-parse -q --verify orchestrate/L12 >/dev/null && pass || fail "and its branch, which holds the only copy of that commit"
here fix-2 "a tree whose branch no board row names is never judged, whatever ticket its name contains"
[ -f "$d/.agents/worktrees/fix-2-apply/prod.plan" ] && pass || fail "a hand-made apply copy, saved plan included, is never touched"
here fix-refactor "a session the operator opened is never touched"; git rev-parse -q --verify worktree-fix-refactor >/dev/null && pass || fail "nor its branch"
here sh "a branch two tickets name is not judged"
has "CARRIED HOME .agents/runs/orchestrate/tickets/L13/results/d13.md from $W/a13" "an old result left in a tree is carried home"
[ "$(cat "$d/.agents/runs/orchestrate/tickets/L13/results/d13.md" 2>/dev/null)" = "only copy" ] && pass || fail "the carried result is in the primary checkout"
gone a13 "and its tree, holding nothing else, is removed"
has "KEPT    $W/a14 (orchestrate/L14) ticket=L14 landed -> it holds files: ?? .agents/runs/orchestrate/tickets/L14/results/d14.md;" "a result that differs from the primary's keeps its tree"
[ "$(cat "$d/.agents/runs/orchestrate/tickets/L14/results/d14.md")" = ours ] && [ "$(cat "$W/a14/.agents/runs/orchestrate/tickets/L14/results/d14.md")" = theirs ] && pass || fail "neither copy of a differing result is changed"

# With nothing new to do it says so in one line, and names only what still needs someone.
out="$(bash "$R" retire 2>&1)"; has "RETIRE: 0 removed, 4 kept" "a second run removes nothing and names the four that hold a file or a lock"
# The count stays while copies do, and a board with no open lanes still says so.
out="$(bash "$R" reground 2>&1)"; has "LANE WORKTREES ON DISK: " "the count stays while copies do"
# Once the file is moved out, the same call finishes the job. A tree with no commits goes when its lane closes.
rm "$W/a4/left.txt"; bash "$R" done L10 2>/dev/null; out="$(bash "$R" retire 2>&1)"
gone a4 "a tree is removed once it holds nothing"; gone a10 "a tree with no commits is removed once its lane is closed"

# --- A writer's handback goes to the primary checkout from inside its own tree, and leaves no copy there.
cd "$W/a2"; mkdir -p .agents/runs/orchestrate/tickets/L2/results
printf 'status: DONE\n<!-- orchestrate:complete -->\n' > .agents/runs/orchestrate/tickets/L2/results/a2.md
out="$(bash "$R" result L2 a2 .agents/runs/orchestrate/tickets/L2/results/a2.md 2>&1)"
assert_eq "$out" "$d/.agents/runs/orchestrate/tickets/L2/results/a2.md" "result prints where the handback now is: the primary checkout"
[ -f "$d/.agents/runs/orchestrate/tickets/L2/results/a2.md" ] && [ ! -e .agents/runs/orchestrate/tickets/L2/results/a2.md ] && pass || fail "the handback is in the primary checkout and its copy in the tree is gone"
[ -z "$(git status --porcelain)" ] && pass || fail "the writer's tree is clean after the handback (got: $(git status --porcelain | tr '\n' ';'))"
t="$(mktemp)"; echo "no sentinel" > "$t"; out="$(bash "$R" result L2 a2b "$t" 2>&1)"; rc=$?
assert_eq "$rc" "0" "a handback without the sentinel is still stored"; has "does not end with the completion sentinel" "and the writer is told it reads as unfinished"
[ -f "$t" ] && pass || fail "a file outside any checkout is left where it was"
# A copy that cannot be stored fails loudly and leaves the writer's file alone, and the earlier result with it.
echo "round two" > r2.md; chmod 555 "$d/.agents/runs/orchestrate/tickets/L2/results"
out="$(bash "$R" result L2 a2 r2.md 2>&1)"; rc=$?; chmod 755 "$d/.agents/runs/orchestrate/tickets/L2/results"
if [ "$(id -u)" = 0 ]; then pass; pass; else
  assert_eq "$rc" "1" "a result that cannot be stored is an error"
  [ -f r2.md ] && has "your file is untouched" "and the writer's file is still there" || fail "a failed store must not remove the writer's file"
fi
rm -f r2.md "$t"
ln -s f.txt link.md; out="$(bash "$R" result L2 a2c link.md 2>&1)"; rc=$?; assert_eq "$rc" "2" "a link handed in as the result is refused"; rm -f link.md
out="$(bash "$R" result ../x a2 f.txt 2>&1)"; rc=$?; assert_eq "$rc" "2" "a ticket that is a path is refused"
out="$(bash "$R" result L2 a2d a2.txt 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f a2.txt ] && pass || fail "a tracked file handed in as the result is copied, never removed"
# In the primary checkout an untracked file handed in is copied and left where it was.
cd "$d"; echo draft > draft.md; out="$(bash "$R" result L2 a2e draft.md 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f draft.md ] && pass || fail "a file in the primary checkout is never removed by a hand-in"
