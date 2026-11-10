# Shared targets and production changes

## Shared-target steps

A step is *worktree-local* when all it reads or changes lives in the lane's own
worktree (edits, unit tests, local builds, lint, `terraform validate`, a plan
against local mocks), and a *shared-target step* when its effect lands outside,
where another lane could touch it at the same moment. The test: *if two lanes
did this at once, could they see or clobber each other's results?* If yes, the
step is serial across all lanes, even when its code was produced in parallel.
Shared targets include a Terraform state backend (plan and apply both), a
cluster or Helm release, a database schema, a package or image registry tag,
one deployment environment, a DNS zone, a shared staging database or physical
device under test, a shared CI pipeline, and a remote branch two lanes both
push to. The planner names each task's `shared_targets`, one exact spelling per
target; treat a task that names none and is not pure code as touching
`unknown`, which serializes with every other `unknown`.

Any plan or apply against a shared target is an actuator task, its own task
`depends_on` the code; implementers never run one. You serialize at dispatch,
since you cannot pause a step inside a running persona: hold a target from its
first plan task until its apply returns, including the wait for the operator,
and dispatch nothing else on it meanwhile. A verifier check that touches the
target (a probe, a plan against real state) is a step on it. The tool's own lock (Terraform's state lock) is
the backstop: a lock error means wait or ask, never force-unlock. This
serialization lives only in this router; another session on the same state is
not seen.

When a second lane's shared-target step follows a first lane's change to the
same target, recreate its worktree from the integration base that now includes
the first lane, then plan again; the operator approves that plan output, not
only the code diff.

## Production changes

An infrastructure change lands as a reviewed diff; actuator tasks plan and then
apply it. The actuator never runs in the operator's checkout: create a fresh
worktree for it at the exact approved commit (the landed integration-base
commit, or the lane's approved commit while its pull request is still open),
`git worktree add --detach .agents/worktrees/<ticket>-apply <sha>`, dispatch it
with that path and SHA. The tree lives from the plan dispatch through the apply
dispatch (the saved plan file stays in it between them); remove it after the
apply lands or the operator declines, and a declined prod-ack also releases the
target for the next lane. The core's
confirmation applies at a `consequence: prod` target (untagged reads as
`prod`): show the operator the target, the commit, and the plan output, with
your recommendation and the risk relative to today, and journal the answer
either way: `ledger.sh decision <ticket> prod-ack:<target> ""
"<approved|declined>: <one line>"`. `safe` targets proceed. The verifier then runs the acceptance
probe.
