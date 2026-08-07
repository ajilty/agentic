# Shipyard ships as a product plugin of user-invoked segments with structural pauses

Shipyard, the four-segment delivery method (scope, shape, spec, ship), lands as
its own plugin rather than as playbooks skills, claiming ADR-0036 test 3:
distinct release cadence with external consumers, because the method is built
for standalone publication. Skills therefore live in-plugin (the product
pattern set by orchestrate), not in the repo-root skills library.

Entry points are five user-invoked skills: the four segments (`/scope`,
`/shape`, `/spec`, `/ship`) plus a `/shipyard` router that reads the on-disk
artifacts, reports where the work stands, and names the next segment to type;
it never executes one. Every skill sets `disable-model-invocation: true`
(Codex sidecar equivalent: `allow_implicit_invocation: false`; opencode has no
such flag and gets defensively worded descriptions). Because no skill can fire
a user-invoked skill, the method's pauses are structural: work continues only
when the human types the next segment.

## Considered options

- playbooks skills (the ADR-0036 default): rejected. The publication intent
  passes test 3, and a system takes a singular product name per the same ADR's
  naming rule.
- A full-run driver skill, alone or alongside the segments over shared
  references: rejected for pause integrity. A driver moves pauses from
  structural to conversational and reintroduces the roll-through failure the
  method exists to prevent.
- Naming orchestrate in skill bodies (the assignment formula): rejected for a
  publishable method. Bodies name the capability ("an installed orchestration
  system", inline single loop as the default); orchestrate appears only in
  shipyard's README.
- Absorbing playbooks' assignment into shipyard as a collapsed mode: rejected.
  That is the rejected driver through the back door, and it entangles the two
  plugins' release cadences.

## Consequences

- Shared conventions (engagement ranking, escalate-on-surprise, time-boxed
  defaults, dual outputs) live once in plugin `references/`; each segment's
  pause contract is unique and stays inline in its skill. The decision log
  stays prose, never a schema.
- Work artifacts (problem statement, decision memo, requirements and build
  specs, decision logs, delta report) are durable human-facing records:
  tracked under `docs/` per ADR-0005. The router locates position by reading
  them.
- Segments tolerate missing predecessor artifacts (shape opens with an inline
  scope-lite when no problem statement exists on disk), which is how the
  method's scaling rule is implemented: enter at any segment, never fewer than
  two pauses.
- Frontmatter descriptions become human-facing one-liners (menu help), not
  model triggers.
- playbooks' assignment is a compressed one-shot of this method. After
  shipyard lands: salvage its copyable-memo contract, baseline-delta scoring,
  and never-fail-if-absent formula into shape and ship, then retire it
  (playbooks README and ADR-0036's illustrative sentence update at that time).
- Design source of truth: `docs/specs/2026-08-07-shipyard-plugin-design.md`.

_Status: active_
