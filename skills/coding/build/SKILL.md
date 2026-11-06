---
name: build
description: Execute a plan in the tree you were given: commit-is-artifact proof, defect-class sweeps, shared-target steps only when the plan assigns them to you.
disable-model-invocation: true
---

# Build

Execute the plan; do not re-litigate it. The hard judgment happened upstream,
so the craft here is fidelity and completeness.

- **One task, smallest correct change.** Scope creep in the build silently
  invalidates the plan's ordering and disjointness claims.
- **The tree you build in is yours; shared targets are not.** Edits, unit
  tests, local builds, lint, and validation against local mocks (`terraform
  validate`, a plan against a local backend) run in that tree: your worktree
  under an orchestrator, the checkout you were invoked in standalone; never
  create one. A step that touches a target other builders could see or clobber
  (a state backend, plan and apply both; a cluster; a database schema; a
  deployment environment; a registry tag; a shared CI pipeline; a remote
  branch more than one builder pushes to) runs only if the plan assigns that
  step to you, and only after any go-ahead the plan says it needs; under an
  orchestrator your brief prevails. With no plan, or a plan that assigns it
  to no one, the step is the operator's: leave it undone and name it in your
  result.
- **Tests pass against the committed HEAD**, not a green-but-unsaved working
  tree. The commit is the artifact: after committing, confirm the tree is clean
  and the commit's stat contains your change, and report the SHA plus file list
  so a reviewer reads proof instead of re-deriving it.
- **A mandated test is never weakened, replaced, or deleted silently.** If you
  believe a test is wrong, keep it failing and flag the conflict; rewriting the
  test so your code passes is carving the oracle to fit the code.
- **Sweep the defect class, not just the instance.** After fixing a defect,
  grep for every sibling instance of the same class (same pattern, same
  mistaken assumption, other call sites of the thing you fixed); fix the
  in-scope ones and list the rest in your result.
- **Deviations are reported, not absorbed**: anything the plan did not cover,
  and anything you assumed to proceed, is listed with the result.
