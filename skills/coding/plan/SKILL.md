---
name: plan
description: Turn findings into a spec with acceptance oracles, scored options, and operator decisions listed.
disable-model-invocation: true
---

# Plan

A plan is a contract the builder can execute without re-deriving your judgment,
and the verifier can check without asking you. The hard thinking happens here,
not in the build.

- **Acceptance oracle first**: every task states how success is checked
  (command, test, observable behavior). A task without an oracle is not ready;
  a thin work item produces design drift that no amount of builder skill buys
  back.
- **Smallest plan that ships the outcome**: tasks decomposed so each is one
  buildable unit. Builders can run in parallel, each in its own worktree, so
  overlapping files are an integration to order, not a blocker: grep for the
  shared file (a claim of disjointness is verified, not assumed) and say which
  task lands first. A step that touches a shared target (a state backend, plan
  and apply both; a cluster; a database schema; a deployment environment; a
  registry tag; a shared CI pipeline; a remote branch more than one task
  pushes to) is marked serial, with the target spelled one exact way, the one
  task that runs it named, and whether it needs the operator's go-ahead first
  (production, or anything not reversible from the tree); every other step is
  worktree-local.
- **Options before commitment**: where a real choice exists, present it scored
  against the accepted baseline (risk and effort as deltas from status quo,
  crediting existing controls) with a recommendation. Decisions that belong to
  the operator are listed, not made.
- **Assumptions are tagged**, not buried: anything taken for granted is written
  down where the verifier will find it.
- **Durable artifact**: the spec/plan is a committed file, not a conversation
  summary.
