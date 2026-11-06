# Single-writer is defined over mutation targets, not files

A writer with run capability can mutate live state (`terraform apply`,
`kubectl apply`, a database) — which git worktrees do **not** isolate. So the
single-writer rail is redefined over **mutation targets** (working tree, tf
state/workspace, cloud account, cluster namespace, database, DNS zone), of which
the working tree is just one. Before dispatching any writer, the loop takes a
per-target **lease**; this serialization is deterministic and fail-closed
(undeclared target → serialize). Credential/backend scoping confines a writer to
its leased targets on a **best-effort** basis.

## Status

accepted

## Considered options

- **Command-interception hook** — parse `terraform apply` etc. and deny unleased
  targets. Rejected as primary: command parsing is open-ended and evadable
  (wrappers, env-var targets, shell indirection) exactly where blast radius is
  highest. Acceptable only as a non-relied-upon backstop.
- **Strict structural credential sandbox** — guarantee confinement. Rejected: not
  enforceable across every harness/deployment.

## Consequences

The Planner must declare `mutation_targets` per task/group, checked like the
independence proof. **Serialization is guaranteed; confinement is advisory** —
the spec must never present confinement as a guarantee (same honesty as the
held-out boundary, orchestrate §7). Defense-in-depth backs it: deterministic
lease + best-effort creds + reviewed diff + the Verifier's independent probe; no
single layer is trusted to be sufficient.

_Status: superseded by 0040_
