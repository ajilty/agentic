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
  captured plan or apply output to the same pattern via its shell. Mint the
  path absolute under the primary checkout's run dir; an isolated writer whose
  harness refuses a write outside its worktree writes the same relative path
  inside its own tree instead, so check both spellings before treating the
  file as absent. The
  `returned` you append carries `branch` and SHA from that file, cross-checked
  with `git worktree list`.
- **Batch by tier:** never bundle a mechanical item with a hard one.
