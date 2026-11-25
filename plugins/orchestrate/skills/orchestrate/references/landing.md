# Worktrees and landing

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
unknown, treat the checkout as shared. Integrating onto the base yourself
also needs a checkout that is not shared and a HEAD that already is the
journaled base; never switch branches or move
HEAD to make that true. A writer's worktree and branch outlive its lane:
nothing removes them, and you do not either without the operator's word.
`ledger.sh leftovers` reports them and changes nothing; run it at landing
and whenever reground counts lane worktrees on disk, since most pull
requests merge in a later turn. That holds for a writer's tree the harness
made as much as one you made. It judges only a tree whose branch a board
row names, and calls one done when everything the branch changed is
already on the base (it compares content, path by path, against the base
as last fetched; fetch first), or when a later round's `dispatched` row
says it replaces that branch and the ticket is closed. Each line is a
state. `LEFT` is not finished and needs nothing. `DONE` is finished and
clean, and carries the commands that would remove it: show the operator
those lines and run the commands only for the trees they say yes to, as
printed, never with `--force`. `HOLDS` is finished but has files or a
lock, each named: show the operator that line too, once, and leave the
tree; a result file it names is yours to store with `ledger.sh result`.
On the hand-over path tree and branch stay, and you tell the operator
where they are. Fix a stale base by recreating
the worktree, never by `reset --hard`. Treat a worktree you did not create as
the operator's; the floor does not cover it.

An instructions change (core step 6 defines it) lands only by
pull request or hand-over, even when the operator asked you to integrate other
lanes directly. A verifier's `APPROVED` never lands it; the operator does, by
merging or by naming that change in an explicit request to land it.
