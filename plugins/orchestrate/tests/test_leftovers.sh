# Lane copies pile up when nothing removes them after the lane ends. `ledger.sh leftovers` reports
# which of this run's trees are finished and prints the commands that would remove them. It
# removes nothing itself: no tree, branch, file, lock or ref, and it does not fetch. It judges
# only a tree whose branch a board row names exactly, whose lane is not in flight, and calls it
# done only when everything the branch changed is on the base (compared by content) or the board
# says a later round replaced it. `ledger.sh result` puts a writer's handback in the primary
# checkout and removes the writer's copy only once the stored one is proven equal. Reground
# counts the copies and changes nothing.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"; d="$(pwd -P)"; git checkout -q -b main 2>/dev/null || git branch -m main
echo base > f.txt; printf '*.plan\n' > .gitignore; git add f.txt .gitignore; git commit -qm init
bash "$R" goal "leftovers test" "" main >/dev/null
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

snap(){ { git worktree list --porcelain; git for-each-ref; git stash list; find "$d" \( -type f -o -type l \) -print | sort | tr '\n' '\0' | xargs -0 cksum; find "$d" | sort; } 2>/dev/null | cksum; }
# A hook that would run if anything rewrote an index, and files touched so that a plain `git status` would.
printf '#!/bin/sh\necho ran >> "%s/hook.log"\n' "$d/.git" > "$d/.git/hooks/post-index-change"; chmod +x "$d/.git/hooks/post-index-change"
touch "$W"/a1/*.txt "$W"/a6/*.txt; rm -f "$d/.git/hook.log"

# Reground counts the copies a board row names, points at leftovers, and changes nothing.
before="$(snap)"
out="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "lane copies on disk are a report, not a halt"
has "LANE WORKTREES ON DISK: " "reground counts the copies of lanes no longer in flight"
has "-> run: ledger.sh leftovers" "and points at leftovers"
has "HAND-MADE COPIES: 1 detached under .agents/worktrees" "reground counts the detached copies the router made by hand"

# Reground's own status check may refresh an index; leftovers must not. Snapshot from here.
touch "$W"/a1/*.txt "$W"/a6/*.txt; rm -f "$d/.git/hook.log"; before="$(snap)"
out="$(bash "$R" leftovers 2>&1)"; rc=$?
assert_eq "$rc" "0" "leftovers is a report"
assert_eq "$(snap)" "$before" "leftovers changes no tree, branch, ref or file, the files under .git included"
[ ! -e "$d/.git/hook.log" ] && pass || fail "leftovers rewrites no index, so the post-index-change hook never runs"
has "DONE    $W/a1 (orchestrate/L1) ticket=L1 landed -> only if the operator says yes: git worktree remove -- $W/a1 && git update-ref -d refs/heads/orchestrate/L1 $(git rev-parse orchestrate/L1)" "a squash-landed lane is done, with the commands to remove it"
has "LEFT    $W/a2 (orchestrate/L2) ticket=L2 -> its lane is open" "an open lane whose change has not landed is left"
has "DONE    $W/a3 (orchestrate/L3) ticket=L3 replaced -> only if the operator says yes: git worktree remove -- $W/a3 " "a round the board says was replaced is done, with no branch deletion offered"
has "DONE    $W/a3r2 (orchestrate/L3-r2) ticket=L3 landed" "the round that landed is done too"
has "LEFT    $W/p1 (orchestrate/P-t1) ticket=P -> not all of it is on main" "parallel tasks of a closed ticket are left, not replaced"
has "LEFT    $W/p2 (orchestrate/P-t2) ticket=P" "both of them"
has "HOLDS   $W/a4 (orchestrate/L4) ticket=L4 landed -> 1 untracked: left.txt ;" "a landed tree with an untracked file holds it, named, with no command"
has "HOLDS   $W/a4i (orchestrate/L4i) ticket=L4i landed -> 1 git-ignored: prod.plan ;" "a landed tree with an ignored file holds it, named"
hasnt "$W/a5 " "an in-flight lane is not judged even when its change is on the base"
has "HOLDS   $W/a6 (orchestrate/L6) ticket=L6 landed -> locked claude agent a6 (pid 1) (the operator's to release);" "a locked tree holds, and its lock is named"
has "LEFT    $W/a7 (orchestrate/L7) ticket=L7 -> not all of it is on main" "a handed-over lane is left"
has "LEFT    $W/a10 (orchestrate/L10) ticket=L10 -> its lane is open and it holds no change of its own yet" "a tree with no commits is left while its lane is open"
has "LEFT    $W/a12 (orchestrate/L12) ticket=L12 -> its lane is open and its change is not on main" "a landed lane with a later commit is left"
hasnt "$W/fix-2 " "a tree whose branch no board row names is never judged, whatever ticket its name contains"
hasnt "fix-2-apply" "a hand-made apply copy is never judged"
hasnt "fix-refactor" "a session the operator opened is never judged"
has "LEFT    $W/sh (orchestrate/shared) -> more than one ticket names its branch" "a branch two tickets name is left, with the reason"
has "HOLDS   $W/a13 (orchestrate/L13) ticket=L13 landed -> run files, perhaps a result nobody stored (ledger.sh result stores one): .agents/runs/orchestrate/tickets/L13/results/d13.md ;" "an old result left in a tree is named, never moved"
has "HOLDS   $W/a14 (orchestrate/L14) ticket=L14 landed -> run files" "and so is one that differs from the primary's"
has "LEFTOVERS: 3 done, 5 done but holding something, " "the last line counts each kind"
has "nothing was removed" "and says nothing was removed"
out="$(bash "$R" leftovers --dry-run 2>&1)"; rc=$?; assert_eq "$rc" "64" "leftovers takes no options"
out="$(bash "$R" retire 2>&1)"; rc=$?; assert_eq "$rc" "64" "there is no command that removes"
# Following a printed command is what removes a tree; a closed lane with no commits becomes done.
# The printed branch deletion names the commit that was judged: a branch that has moved since is not deleted.
l1="$(git rev-parse orchestrate/L1)"; ( cd "$W/a1" && echo late > late.txt && git add late.txt && git commit -qm "after the report" )
git update-ref -d refs/heads/orchestrate/L1 "$l1" 2>/dev/null && fail "a branch that moved after the report must not be deleted by the printed command" || pass
out="$(bash "$R" leftovers 2>&1)"; has "LEFT    $W/a1 (orchestrate/L1) ticket=L1" "and the next report no longer calls it done"
git -C "$W/a1" reset -q --hard "$l1"; git worktree remove "$W/a1" && git update-ref -d refs/heads/orchestrate/L1 "$l1"; bash "$R" done L10 2>/dev/null
out="$(bash "$R" leftovers 2>&1)"; hasnt "$W/a1 " "a tree someone removed is no longer listed"
has "DONE    $W/a10 (orchestrate/L10) ticket=L10 landed" "a tree with no commits is done once its lane is closed"

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
out="$(bash "$R" result . a2 f.txt 2>&1)"; rc=$?; assert_eq "$rc" "2" "a ticket that is a dot is refused"
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

# --- With an origin, the base is origin's as last fetched. Cases where the branch only looks merged.
o="$(mktemp -d)"; git init -q --bare "$o/o.git"
d="$(mktemp_repo)"; cd "$d"; d="$(pwd -P)"; git checkout -q -b main 2>/dev/null || git branch -m main
printf 'one\ntwo\nthree\n' > f.txt; echo old > legacy.txt; git add f.txt legacy.txt; git commit -qm init
git remote add origin "$o/o.git"; git push -q origin main; bash "$R" goal "leftovers with origin" "" main >/dev/null
W="$d/.claude/worktrees"; land(){ squash "$1"; git push -q origin main; }
# The writer deletes a file the base has since edited: nothing proves that merged.
lane C1 orchestrate/C1 c1; ( cd "$W/c1" && git rm -q legacy.txt && git commit -qm "drop legacy" )
echo newer > legacy.txt; git commit -qam "base edits legacy"; git push -q origin main
# A squash merge whose lines the base edited afterwards: still that branch's whole change, in one commit.
lane S1 orchestrate/S1 s1; ( cd "$W/s1" && printf 'one\nTWO\nthree\n' > f.txt && git commit -qam "shout two" ); land orchestrate/S1
printf 'one\nTWO!\nthree\n' > f.txt; git commit -qam "base edits the same line"; git push -q origin main
# A retry built on the round it replaces.
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
# A file named like pathspec magic, never merged: compared by its literal name.
lane X1 orchestrate/X1 x1; ( cd "$W/x1" && echo n > ':(top)f.txt' && mkdir : && echo n > ':/f.txt' && git add -A . && git commit -qm "odd names" )
# A tracked file git was told not to watch, edited on disk, with a quote in its name.
echo v > 'say "hi".txt'; git add 'say "hi".txt'; git commit -qm quoted; git push -q origin main
lane H1 orchestrate/H1 h1; land orchestrate/H1; ( cd "$W/h1" && git update-index --assume-unchanged 'say "hi".txt' && echo edited > 'say "hi".txt' )
# A commit kept only under a ref of the tree's own, which goes when the tree does.
lane WR orchestrate/WR wr; land orchestrate/WR; ( cd "$W/wr" && git update-ref refs/worktree/keep HEAD )
# A merge stopped midway in a landed tree: its only trace is in the tree's own git dir.
lane MG orchestrate/MG mg; land orchestrate/MG; ( cd "$W/mg" && git merge -q --no-commit -s ours orchestrate/Q1 >/dev/null 2>&1 || true )
# A tree whose path needs quoting in a command.
lane SP orchestrate/SP "s p"; land orchestrate/SP
# Landed locally but never pushed: origin's base does not hold it.
lane U1 orchestrate/U1 u1; squash orchestrate/U1
row '{"ticket":"P|done","event":"dispatched","persona":"implementer","dispatch_id":"pipe","branch":"orchestrate/pipe"}'; tree orchestrate/pipe pipe
# Run from a folder below the top: the verdicts must not depend on where the caller stands.
before="$(snap)"; mkdir -p "$d/deep/er"; before="$(snap)"; out="$(cd "$d/deep/er" && bash "$R" leftovers 2>&1)"
assert_eq "$(snap)" "$before" "from a subfolder too, nothing changes"
has "LEFT    $W/c1 (orchestrate/C1) ticket=C1 -> its lane is open" "a branch whose change conflicts with the base is not read as merged"
has "DONE    $W/s1 (orchestrate/S1) ticket=S1 landed" "a squash merge the base later edited is still recognised"
has "DONE    $W/r1 (orchestrate/R1) ticket=R1 replaced" "a replaced round is done"
has "LEFT    $W/r1b (orchestrate/R1-r2) ticket=R1" "the retry's own tree waits for its merge"
has "HOLDS   $W/m1 (orchestrate/M1) ticket=M1 landed ->  M m1.txt;" "a landed tree with an uncommitted change holds it, named"
has "LEFT    $W/q1 (orchestrate/Q1) ticket=Q1 -> its lane is open" "the same edit made elsewhere on the base is not this branch landing"
has "DONE    $W/dead (worktree-agent-dead) ticket=D1 replaced" "a round that died is done once the retry that replaces it is closed"
has "LEFT    $W/x1 (orchestrate/X1) ticket=X1 -> its lane is open" "a file named like pathspec magic is compared, not skipped"
has "HOLDS   $W/h1 (orchestrate/H1) ticket=H1 landed -> 1 tracked files git was told not to watch" "a hidden edit to a file with a quote in its name is seen"
has "git worktree remove -- $W/s\\ p && git update-ref -d refs/heads/orchestrate/SP $(git rev-parse orchestrate/SP)" "a path with a space is quoted in the printed command"
has "HOLDS   $W/wr (orchestrate/WR) ticket=WR landed -> refs of its own that go with it: refs/worktree/keep ;" "a ref of the tree's own holds it"
has "HOLDS   $W/mg (orchestrate/MG) ticket=MG landed -> an operation stopped midway" "a merge stopped midway holds the tree"
has "LEFT    $W/u1 (orchestrate/U1) ticket=U1" "a change on the local base that origin does not hold is not landed"
hasnt "$W/pipe " "a ticket whose id holds the field separator is never judged"
has "judged against origin/main as last fetched" "the last line says what it judged against"
# It never fetches: an origin that cannot be reached changes nothing about the answer.
git remote set-url origin "$o/missing.git"; out2="$(cd "$d/deep/er" && bash "$R" leftovers 2>&1)"; assert_eq "$out2" "$out" "an unreachable origin gives the same report: it does not fetch"
git remote set-url origin "$o/o.git"
bash "$R" goal "bad base" "" "--upload-pack=touch $o/pwned" >/dev/null; out="$(bash "$R" leftovers 2>&1)"
has "not a branch name: nothing judged" "a base that is an option is refused"; [ ! -e "$o/pwned" ] && pass || fail "and never reaches git as one"
git remote remove origin; bash "$R" done C1 2>/dev/null; bash "$R" goal "own base" "" orchestrate/C1 >/dev/null
out="$(bash "$R" leftovers 2>&1)"; hasnt "$W/c1 " "a lane whose branch the board names as the base is never judged against itself"
rm -rf "${o:?}"
# A partial clone is not judged: comparing content there would download it.
git config remote.origin.promisor true 2>/dev/null || git config remote.x.promisor true
out="$(bash "$R" leftovers 2>&1)"; has "partial clone" "a partial clone is not judged"
