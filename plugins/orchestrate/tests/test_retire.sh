# Lane copies go when the lane's work has ended, and only then: `ledger.sh retire` removes the
# worktree of a lane whose change landed (squash merge, merge, or a merged pull request) or was
# superseded by a later round, keeps anything with work in it, and never judges another
# session's tree. `ledger.sh result` puts a writer's handback in the primary checkout, so no
# result file is left to keep a tree alive. Reground counts the copies and changes nothing.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"; d="$(pwd -P)"; git checkout -q -b main 2>/dev/null || git branch -m main
echo base > f.txt; git add f.txt; git commit -qm init
bash "$R" goal "retire test" "" main >/dev/null
lane(){ # <ticket> <branch> <dir>: a writer's tree with one commit, journaled as returned
  git worktree add -q -b "$2" "$d/.claude/worktrees/$3" main
  ( cd "$d/.claude/worktrees/$3" && echo "$2" > "$3.txt" && git add "$3.txt" && git commit -qm "$1: work" )
  bash "$R" append "{\"ticket\":\"$1\",\"event\":\"dispatched\",\"persona\":\"implementer\",\"dispatch_id\":\"$3\",\"branch\":\"$2\"}"
  bash "$R" append "{\"ticket\":\"$1\",\"event\":\"returned\",\"persona\":\"implementer\",\"status\":\"DONE\",\"branch\":\"$2\"}"
}
squash(){ git merge -q --squash "$1" >/dev/null && git commit -qm "$1 squashed"; }   # the base takes the branch as one commit
has(){ case "$out" in *"$1"*) pass ;; *) fail "$2 (got: $out)" ;; esac; }
hasnt(){ case "$out" in *"$1"*) fail "$2 (got: $out)" ;; *) pass ;; esac; }

# --- a lane whose change is on the base as a squash commit: tree and branch go, lane still open or not
lane L1 orchestrate/L1 a1; squash orchestrate/L1
# --- a lane whose pull request is still open: nothing lands, so nothing goes
lane L2 orchestrate/L2 a2
# --- a ticket retried: round 1 never landed, round 2 did, and the ticket is closed
lane L3 orchestrate/L3 a3; lane L3 orchestrate/L3-r2 a3r2; squash orchestrate/L3-r2; bash "$R" done L3 2>/dev/null
# --- landed, but with a file left in it
lane L4 orchestrate/L4 a4; squash orchestrate/L4; echo note > "$d/.claude/worktrees/a4/left.txt"
# --- in flight: dispatched, not returned
git worktree add -q -b orchestrate/L5 "$d/.claude/worktrees/a5" main
bash "$R" append '{"ticket":"L5","event":"dispatched","persona":"implementer","dispatch_id":"a5","branch":"orchestrate/L5"}'
# --- another session's tree: no board row, no ticket in its name
git worktree add -q -b somebody-else "$d/.claude/worktrees/other" main
# --- landed and locked
lane L6 orchestrate/L6 a6; squash orchestrate/L6; git worktree lock --reason "claude agent a6 (pid 1)" "$d/.claude/worktrees/a6"
# --- closed, last branch, not landed: handed over or waiting for its merge
lane L7 orchestrate/L7 a7; bash "$R" done L7 2>/dev/null
# --- a detached apply copy: kept while its lane is open, gone once it is closed
bash "$R" append '{"ticket":"L8","event":"intake","tier":"T2"}'; git worktree add -q --detach "$d/.agents/worktrees/L8-apply" main
bash "$R" append '{"ticket":"L9","event":"intake","tier":"T2"}'; git worktree add -q --detach "$d/.agents/worktrees/L9-apply" main; bash "$R" done L9 2>/dev/null
# --- returned with no commit of its own, lane still open: its builder may be sent back in
git worktree add -q -b orchestrate/L10 "$d/.claude/worktrees/a10" main
bash "$R" append '{"ticket":"L10","event":"returned","persona":"implementer","status":"BLOCKED","branch":"orchestrate/L10"}'

# Reground counts them, points at retire, and changes nothing.
before="$(git worktree list | wc -l | tr -d ' ')"
out="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "lane copies on disk are a report, not a halt"
has "LANE WORKTREES ON DISK: 8 whose lane is not in flight -> run: ledger.sh retire" "reground counts the copies of lanes no longer in flight"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "$before" "reground removes nothing"

# A dry run says what would go and removes nothing.
out="$(bash "$R" retire --dry-run 2>&1)"
has "WOULD RETIRE $d/.claude/worktrees/a1 (orchestrate/L1) ticket=L1 landed" "a dry run names a landed lane's tree"
assert_eq "$(git worktree list | wc -l | tr -d ' ')" "$before" "a dry run removes nothing"

out="$(bash "$R" retire 2>&1)"
has "RETIRED $d/.claude/worktrees/a1 (orchestrate/L1) ticket=L1 landed" "a squash-landed lane's tree is removed"
[ ! -e "$d/.claude/worktrees/a1" ] && ! git rev-parse -q --verify orchestrate/L1 >/dev/null && pass || fail "a landed lane's tree and branch are gone"
[ -d "$d/.claude/worktrees/a2" ] && git rev-parse -q --verify orchestrate/L2 >/dev/null && pass || fail "an open lane whose change has not landed keeps its tree and branch"
hasnt "worktrees/a2 " "an open, unlanded lane is not mentioned"
has "RETIRED $d/.claude/worktrees/a3 (orchestrate/L3) ticket=L3 superseded; branch kept" "a superseded round's tree is removed"
[ ! -e "$d/.claude/worktrees/a3" ] && git rev-parse -q --verify orchestrate/L3 >/dev/null && pass || fail "a superseded round loses its tree and keeps its branch"
[ ! -e "$d/.claude/worktrees/a3r2" ] && pass || fail "the round that landed is removed too"
has "KEPT    $d/.claude/worktrees/a4 (orchestrate/L4) ticket=L4 landed -> uncommitted or untracked files: ?? left.txt" "a landed tree with a file left in it is kept and the file named"
[ -f "$d/.claude/worktrees/a4/left.txt" ] && pass || fail "a file left in a tree is never removed"
[ -d "$d/.claude/worktrees/a5" ] && pass || fail "an in-flight lane keeps its tree"; hasnt "worktrees/a5 " "an in-flight lane is not mentioned"
[ -d "$d/.claude/worktrees/other" ] && pass || fail "another session's tree is never touched"; hasnt "worktrees/other" "another session's tree is not mentioned"
has "KEPT    $d/.claude/worktrees/a6 (orchestrate/L6) ticket=L6 landed -> locked" "a locked tree is kept and the lock named"
[ -d "$d/.claude/worktrees/a6" ] && pass || fail "a locked tree stays"
has "KEPT    $d/.claude/worktrees/a7 (orchestrate/L7) ticket=L7 -> lane closed, change not on main yet" "a closed lane's last branch waits for its merge"
[ -d "$d/.claude/worktrees/a7" ] && pass || fail "a handed-over lane keeps its tree"
[ -d "$d/.agents/worktrees/L8-apply" ] && pass || fail "an apply copy of an open lane stays"
has "RETIRED $d/.agents/worktrees/L9-apply (detached) ticket=L9 lane closed" "an apply copy of a closed lane is removed"
[ ! -e "$d/.agents/worktrees/L9-apply" ] && pass || fail "the closed lane's apply copy is gone"
[ -d "$d/.claude/worktrees/a10" ] && pass || fail "a tree with no commits stays while its lane is open"
has "RETIRE: 4 removed, 3 kept" "the last line counts both"

# Once the file is gone and the lock released, the same call finishes the job; with nothing left it says so.
rm "$d/.claude/worktrees/a4/left.txt"; git worktree unlock "$d/.claude/worktrees/a6"
out="$(bash "$R" retire 2>&1)"
[ ! -e "$d/.claude/worktrees/a4" ] && [ ! -e "$d/.claude/worktrees/a6" ] && pass || fail "a tree is removed once nothing holds it (got: $out)"
# A tree with no commits goes when its lane closes.
bash "$R" done L10 2>/dev/null; out="$(bash "$R" retire 2>&1)"
[ ! -e "$d/.claude/worktrees/a10" ] && pass || fail "a tree with no commits is removed once its lane is closed (got: $out)"

# A pull request merged under the branch's name counts as landed even when the base's commit differs.
lane L11 orchestrate/L11 a11; mkdir -p "$d/bin"
printf '#!/bin/sh\ncase "$*" in *"--head orchestrate/L11"*) echo 42 ;; esac\n' > "$d/bin/gh"; chmod +x "$d/bin/gh"
out="$(PATH="$d/bin:$PATH" bash "$R" retire 2>&1)"
has "RETIRED $d/.claude/worktrees/a11 (orchestrate/L11) ticket=L11 landed" "a merged pull request under the branch name lands the lane"
out="$(PATH="$d/bin:$PATH" bash "$R" retire 2>&1)"; hasnt "worktrees/a2 " "a pull request merged for one branch says nothing about another"
[ -d "$d/.claude/worktrees/a2" ] && pass || fail "the lane without a merged pull request still has its tree"

# --- A writer's handback goes to the primary checkout from inside its own tree, and leaves no copy there.
cd "$d/.claude/worktrees/a2"; mkdir -p .agents/runs/orchestrate/tickets/L2/results
printf 'status: DONE\n<!-- orchestrate:complete -->\n' > .agents/runs/orchestrate/tickets/L2/results/a2.md
out="$(bash "$R" result L2 a2 .agents/runs/orchestrate/tickets/L2/results/a2.md 2>&1)"
assert_eq "$out" "$d/.agents/runs/orchestrate/tickets/L2/results/a2.md" "result prints where the handback now is: the primary checkout"
[ -f "$d/.agents/runs/orchestrate/tickets/L2/results/a2.md" ] && [ ! -e .agents/runs/orchestrate/tickets/L2/results/a2.md ] && pass || fail "the handback is in the primary checkout and its copy in the tree is gone"
[ -z "$(git status --porcelain)" ] && pass || fail "the writer's tree is clean after the handback (got: $(git status --porcelain | tr '\n' ';'))"
t="$(mktemp)"; echo "no sentinel" > "$t"; out="$(bash "$R" result L2 a2b "$t" 2>&1)"; rc=$?
assert_eq "$rc" "0" "a handback without the sentinel is still stored"; has "does not end with the completion sentinel" "and the writer is told it reads as unfinished"
[ -f "$t" ] && pass || fail "a file outside any checkout is left where it was"; rm -f "$t"
out="$(bash "$R" result ../x a2 f.txt 2>&1)"; rc=$?; assert_eq "$rc" "2" "a ticket that is a path is refused"
out="$(bash "$R" result L2 a2 a2.txt 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f a2.txt ] && pass || fail "a tracked file handed in as the result is copied, never removed"
cd "$d"
