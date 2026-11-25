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
has "HAND-MADE COPIES: 1 detached under .agents/worktrees" "reground counts the detached copies the router made by hand"
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
here a2 "an open lane whose change has not landed keeps its tree"; has "LEFT    $W/a2 (orchestrate/L2) ticket=L2 -> its lane is open" "and is named as left"
has "RETIRED $W/a3 (orchestrate/L3) ticket=L3 replaced; branch kept" "a round the board says was replaced loses its tree"
gone a3 "the replaced round's tree is gone"; git rev-parse -q --verify orchestrate/L3 >/dev/null && pass || fail "a replaced round keeps its branch"
gone a3r2 "the round that landed is removed too"
here p1 "a closed ticket's unmerged task keeps its tree"; here p2 "and so does its other task: neither replaces the other"
has "LEFT    $W/p1 (orchestrate/P-t1) ticket=P -> not all of it is on main" "parallel tasks of a closed ticket are named as left, not replaced"
has "KEPT    $W/a4 (orchestrate/L4) ticket=L4 landed -> it holds files: ?? left.txt;" "a landed tree with an untracked file is kept and the file named"
[ -f "$W/a4/left.txt" ] && pass || fail "an untracked file is never removed"
has "KEPT    $W/a4i (orchestrate/L4i) ticket=L4i landed -> only 1 git-ignored entries (prod.plan) remain: when the operator agrees they can go, run retire --ignored $W/a4i" "a landed tree with only an ignored file is kept and the file named"
[ -f "$W/a4i/prod.plan" ] && pass || fail "an ignored file is never removed"
here a5 "an in-flight lane keeps its tree even when its change is on the base"; hasnt "$W/a5 " "and is not mentioned"
has "KEPT    $W/a6 (orchestrate/L6) ticket=L6 landed -> locked claude agent a6 (pid 1): retire never unlocks" "a locked tree is kept and its lock named"
here a6 "a locked tree stays"; [ -f "$d/.git/worktrees/a6/locked" ] && pass || fail "the lock is still in place"
here a7 "a handed-over lane keeps its tree"; has "LEFT    $W/a7 (orchestrate/L7) ticket=L7 -> not all of it is on main" "and is named as left"
here a10 "a tree with no commits stays while its lane is open"
here a12 "a landed lane with a later commit keeps its tree"; git rev-parse -q --verify orchestrate/L12 >/dev/null && pass || fail "and its branch, which holds the only copy of that commit"
here fix-2 "a tree whose branch no board row names is never judged, whatever ticket its name contains"
[ -f "$d/.agents/worktrees/fix-2-apply/prod.plan" ] && pass || fail "a hand-made apply copy, saved plan included, is never touched"
here fix-refactor "a session the operator opened is never touched"; git rev-parse -q --verify worktree-fix-refactor >/dev/null && pass || fail "nor its branch"
here sh "a branch two tickets name is not judged"; has "LEFT    $W/sh (orchestrate/shared) -> more than one ticket names its branch" "and the reason is given"
has "CARRIED HOME .agents/runs/orchestrate/tickets/L13/results/d13.md from $W/a13" "an old result left in a tree is carried home"
[ "$(cat "$d/.agents/runs/orchestrate/tickets/L13/results/d13.md" 2>/dev/null)" = "only copy" ] && pass || fail "the carried result is in the primary checkout"
gone a13 "and its tree, holding nothing else, is removed"
has "KEPT    $W/a14 (orchestrate/L14) ticket=L14 landed -> it holds files: ?? .agents/runs/orchestrate/tickets/L14/results/d14.md;" "a result that differs from the primary's keeps its tree"
[ "$(cat "$d/.agents/runs/orchestrate/tickets/L14/results/d14.md")" = ours ] && [ "$(cat "$W/a14/.agents/runs/orchestrate/tickets/L14/results/d14.md")" = theirs ] && pass || fail "neither copy of a differing result is changed"

# With nothing new to do it says so in one line, and names only what still needs someone.
out="$(bash "$R" retire 2>&1)"; has "RETIRE: 0 removed, 4 kept" "a second run removes nothing and names the four that hold a file or a lock"
# Ignored files go with a tree only when the caller says they may, and are named when they do.
out="$(bash "$R" retire --ignored 2>&1)"; rc=$?; assert_eq "$rc" "64" "--ignored without a tree is refused"
out="$(bash "$R" retire --ignored "$W/a4" 2>&1)"
has "KEPT    $W/a4i (orchestrate/L4i) ticket=L4i landed -> only 1 git-ignored" "--ignored for one tree does not reach another"
has "KEPT    $W/a4 (orchestrate/L4) ticket=L4 landed -> it holds files: ?? left.txt;" "and still keeps a tree with an untracked file"
mkdir -p "$W/a4i/build/inner"; git init -q "$W/a4i/build/inner"; printf 'build/\n' >> "$d/.git/info/exclude"
out="$(bash "$R" retire --ignored "$W/a4i" 2>&1)"
has "KEPT    $W/a4i (orchestrate/L4i) ticket=L4i landed -> one of its git-ignored folders holds a repository" "a repository inside an ignored folder keeps the tree even with --ignored"
rm -rf "$W/a4i/build"; out="$(bash "$R" retire --ignored "$W/a4i" 2>&1)"
has "RETIRED $W/a4i (orchestrate/L4i) ticket=L4i landed; 1 git-ignored entries (prod.plan) went with it" "with --ignored its tree holding only ignored files goes, and they are named"
out="$(bash "$R" retire --force 2>&1)"; rc=$?; assert_eq "$rc" "64" "an unknown option is refused"
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

# A second hand-in never replaces a stored result that differs, and a folder where the result belongs is refused.
echo other > other.md; out="$(bash "$R" result L2 a2e other.md 2>&1)"; rc=$?
assert_eq "$rc" "1" "a second hand-in that differs from the stored result is an error"
[ "$(cat "$d/.agents/runs/orchestrate/tickets/L2/results/a2e.md")" = draft ] && [ -f other.md ] && pass || fail "the stored result and the second file are both unchanged"
out="$(bash "$R" result L2 a2e draft.md 2>&1)"; rc=$?; assert_eq "$rc" "0" "handing the same result in again is fine"
mkdir -p "$d/.agents/runs/orchestrate/tickets/L2/results/dir.md"; out="$(bash "$R" result L2 dir other.md 2>&1)"; rc=$?
assert_eq "$rc" "1" "a folder where the result belongs is an error"; [ -f other.md ] && [ -z "$(ls -A "$d/.agents/runs/orchestrate/tickets/L2/results/dir.md")" ] && pass || fail "nothing is put inside that folder"
[ -z "$(ls -A "$d/.agents/runs/orchestrate/tickets/L2/results" | grep '^\.')" ] && pass || fail "no temporary file is left beside the results"

# --- With an origin, the base is origin's, fetched first. Cases where the branch only looks merged.
o="$(mktemp -d)"; git init -q --bare "$o/o.git"
d="$(mktemp_repo)"; cd "$d"; d="$(pwd -P)"; git checkout -q -b main 2>/dev/null || git branch -m main
printf 'one\ntwo\nthree\n' > f.txt; echo old > legacy.txt; git add f.txt legacy.txt; git commit -qm init
git remote add origin "$o/o.git"; git push -q origin main; bash "$R" goal "retire with origin" "" main >/dev/null
W="$d/.claude/worktrees"; land(){ squash "$1"; git push -q origin main; }
# The writer deletes a file the base has since edited: the merge conflicts, so nothing is proven merged.
lane C1 orchestrate/C1 c1; ( cd "$W/c1" && git rm -q legacy.txt && git commit -qm "drop legacy" )
echo newer > legacy.txt; git commit -qam "base edits legacy"; git push -q origin main
# A squash merge whose lines the base edited afterwards: still that branch's whole change, in one commit.
lane S1 orchestrate/S1 s1; ( cd "$W/s1" && printf 'one\nTWO\nthree\n' > f.txt && git commit -qam "shout two" ); land orchestrate/S1
printf 'one\nTWO!\nthree\n' > f.txt; git commit -qam "base edits the same line"; git push -q origin main
# A retry built on the round it replaces: the replaced branch's commits live on in the retry's branch.
lane R1 orchestrate/R1 r1
git worktree add -q -b orchestrate/R1-r2 "$W/r1b" orchestrate/R1; ( cd "$W/r1b" && echo fix > fix.txt && git add fix.txt && git commit -qm "fix" )
row '{"ticket":"R1","event":"dispatched","persona":"implementer","dispatch_id":"r1b","replaces":"orchestrate/R1"}'
row '{"ticket":"R1","event":"returned","persona":"implementer","status":"DONE","branch":"orchestrate/R1-r2"}'; bash "$R" done R1 2>/dev/null
# A tracked file changed and not committed in a landed tree.
lane M1 orchestrate/M1 m1; land orchestrate/M1; echo edit >> "$W/m1/m1.txt"
# The base makes the branch's very edit somewhere else: two identical stanzas, the branch
# changes the first, an unrelated base commit changes the second. Same patch, different place.
printf 'a {\n  size = small\n}\nx\ny\nz\nw\nv\nu\nb {\n  size = small\n}\n' > twin.txt; git add twin.txt; git commit -qm twin; git push -q origin main
lane Q1 orchestrate/Q1 q1; ( cd "$W/q1" && sed -i.bak '2s/small/large/' twin.txt && rm -f twin.txt.bak && git commit -qam "first stanza large" )
sed -i.bak '11s/small/large/' twin.txt && rm -f twin.txt.bak; git commit -qam "second stanza large"; git push -q origin main
# A round that died before returning: no row names its branch but the retry's "replaces".
tree worktree-agent-dead dead; row '{"ticket":"D1","event":"dispatched","persona":"implementer","dispatch_id":"dead"}'
git worktree add -q -b orchestrate/D1-r2 "$W/d1b" worktree-agent-dead
row '{"ticket":"D1","event":"dispatched","persona":"implementer","dispatch_id":"d1b","replaces":"worktree-agent-dead"}'
row '{"ticket":"D1","event":"returned","persona":"implementer","status":"DONE","branch":"orchestrate/D1-r2"}'; bash "$R" done D1 2>/dev/null
# Landed locally but never pushed: origin's base does not hold it.
lane U1 orchestrate/U1 u1; squash orchestrate/U1
out="$(bash "$R" retire 2>&1)"
has "LEFT    $W/c1 (orchestrate/C1) ticket=C1 -> its lane is open" "a branch whose merge conflicts is not read as merged"
here c1 "its tree stays"; git rev-parse -q --verify orchestrate/C1 >/dev/null && pass || fail "and its branch"
has "RETIRED $W/s1 (orchestrate/S1) ticket=S1 landed" "a squash merge the base later edited is still recognised"
has "RETIRED $W/r1 (orchestrate/R1) ticket=R1 replaced; branch deleted, its commits are on orchestrate/R1-r2" "a replaced round whose commits live on in the retry loses its branch too"
here r1b "the retry's own tree waits for its merge"
has "KEPT    $W/m1 (orchestrate/M1) ticket=M1 landed -> it holds files:  M m1.txt;" "a landed tree with an uncommitted change is kept and the file named"
has "LEFT    $W/q1 (orchestrate/Q1) ticket=Q1 -> its lane is open" "the same edit made elsewhere on the base is not this branch landing"
git rev-parse -q --verify orchestrate/Q1 >/dev/null && pass || fail "and its branch stays"
has "RETIRED $W/dead (worktree-agent-dead) ticket=D1 replaced; branch deleted, its commits are on orchestrate/D1-r2" "a round that died is removed once the retry that replaces it is closed"
has "LEFT    $W/u1 (orchestrate/U1) ticket=U1" "a change on the local base that origin does not hold is not landed"
# A fetch that fails judges nothing; a base that is not a branch name, or is the lane's own branch, removes nothing.
git remote set-url origin "$o/missing.git"; out="$(bash "$R" retire 2>&1)"
has "RETIRE: could not fetch main from origin: nothing judged" "a failed fetch judges nothing"; here u1 "and removes nothing"
git remote set-url origin "$o/o.git"
bash "$R" goal "bad base" "" "--upload-pack=touch $o/pwned" >/dev/null; out="$(bash "$R" retire 2>&1)"
has "not a branch name: nothing judged" "a base that is an option is refused"; [ ! -e "$o/pwned" ] && pass || fail "and never reaches git as one"
git remote remove origin; bash "$R" done U1 2>/dev/null; bash "$R" goal "own base" "" orchestrate/C1 >/dev/null; bash "$R" done C1 2>/dev/null
out="$(bash "$R" retire 2>&1)"; here c1 "a lane whose branch the board names as the base is never judged against itself"
git rev-parse -q --verify orchestrate/C1 >/dev/null && pass || fail "and keeps its branch"
rm -rf "${o:?}"
