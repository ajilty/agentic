# Worktrees and landing

Router reference (core: `../SKILL.md`, loop steps 2 and 7). The worktree base check at intake and how an approved change lands.

## Worktrees and landing

At intake, check once that the harness's worktree base equals `goal.base`:
`git symbolic-ref --short refs/remotes/origin/HEAD` prints `origin/<base>` (with
none cached, the harness cuts from local HEAD); with `worktree.baseRef: "head"`
set, `git rev-parse --abbrev-ref HEAD` does. On a mismatch, give the operator
the fix (`git remote set-head origin <base>`, which moves the base for every
session in the repo, or that setting) and dispatch no writer until it matches.

Land on `APPROVED` with the verdict file on disk; never chain persisting it
and landing in one command. The operator's working agreements outrank this
brief. Before touching the shared checkout, check for another writer: `git
status --porcelain` for paths you did not write, `git worktree list` for trees
you did not create, and, where the harness exposes it, the session or agent
list (`herdr agent list`, or the harness's own). If any is non-empty or
unknown, treat the checkout as shared. By default push the lane's branch and
open a pull request, or hand the change over and ask. Integrate onto the base
directly only when the operator asked for that in this run, the checkout is not
shared, and HEAD already is the journaled base; never switch branches or move
HEAD to make that true. Remove a lane's worktree and branch only after its
change has landed (merged, or its pull request merged); on the hand-over path
keep both and tell the operator where they are. Fix a stale base by recreating
the worktree, never by `reset --hard`. Treat a worktree you did not create as
the operator's; the floor does not cover it.

An instructions change (a skill, a persona brief) never lands on its own
approval, whatever the operator asked for other lanes: open the pull request
or hand it over, and bring the operator every finding you did not fix.

In a long session, a closed lane on a quiet board is the cheapest compaction
point: tell the operator "clean boundary: good time for `/compact keep the goal
and open lanes; the board on disk is authoritative`".
