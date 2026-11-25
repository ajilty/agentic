# Dispatching

The detail behind the core's every-dispatch rules. Each persona already carries
its craft guide; add none.

- **Journal row.** A troubleshooter journals as `researcher`; a researcher's
  row adds a ticket-unique `slug`, a lens verifier's its `lens`.
- **Isolate writers.** Several implementers may run at once, each in its own
  tree. Without native
  isolation, run `git worktree add -b orchestrate/<ticket>
  .agents/worktrees/<ticket> origin/<base>` yourself so reground sees it.
  Prefer disjoint tasks; landing and the verifier catch coupling.
- **A retry goes back to the builder that built it.** Resume that implementer
  by its agent id; it keeps its context and works on in its own tree, so one
  ticket holds one tree however many rounds it takes. Dispatch a fresh
  implementer only when the first cannot be resumed (it was stopped, or its
  transcript is gone), and say so in the `dispatched` row's note; `retire`
  removes the tree it replaces once the ticket is closed.
- **Hand over only the artifact:** the work item or spec task, the paths it
  needs, its result path; on a retry, the verdict file; on a plan revision,
  the prior verdict and its pin; on a plan re-review, those two plus the
  planner's change list (`<spec>.changes.md`). Name any held-out path in an implementer's dispatch
  as off-limits; hand that path to the verifier. For a bug fix, say the
  implementer writes a repro test first and shows it red.
- **Mint result paths and read them from disk.** A researcher writes
  `tickets/<ticket>/findings/_quarantine/<slug>.<dispatch_id>.md`, a verifier
  `tickets/<ticket>/verdicts/<ticket>.<dispatch_id>.md`, a planner its spec
  path, each ending with the sentinel; no file means re-dispatch. Promote a
  researcher's file (Quarantine) to `tickets/<ticket>/findings/<slug>.md`, then
  append `returned`; append `verdict` after reading the verdict file. Writers
  write results too: an implementer's last act is
  `tickets/<ticket>/results/<dispatch_id>.md` (status, branch, commit SHA, file
  list, open tags) ending with the sentinel, and an actuator writes its
  captured plan or apply output to the same pattern. A writer hands the file
  in with `ledger.sh result <ticket> <dispatch_id> <file>`, which stores it
  under the primary checkout's run dir from inside any worktree and leaves no
  copy in the writer's tree: a result left there is untracked work that keeps
  the tree alive after the lane ends. Read it at the path under the primary
  checkout; for a writer dispatched before 0.9.8, also check the same relative
  path inside its tree before treating the file as absent. The
  `returned` you append carries `branch` and SHA from that file, cross-checked
  with `git worktree list`.
- **Batch by tier:** never bundle a mechanical item with a hard one.
