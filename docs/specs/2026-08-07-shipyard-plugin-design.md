# Shipyard plugin design

**Date:** 2026-08-07
**Status:** Approved (decisions recorded in [ADR-0039](../adr/0039-shipyard-product-plugin-structural-pauses.md))

**Scope it, shape it, spec it, ship it.**

Shipyard is a four-segment workflow system that steers an agent through taking
an idea, need, or problem from raw ask to shipped result, with the human
engaged only at the points where engagement actually matters. It is
opinionated about two things: **pause at commitments, not at effort**, and
**assert, don't ask**.

These are workflow skills, not knowledge skills. The model already knows how
to do discovery, options analysis, requirements engineering, and delivery.
What it lacks without steering is repeatable discipline: it over-asks,
under-escalates the irreversible, batches decisions badly, and infers approval
from silence. Each skill encodes the discipline for one segment, and the seams
between them are the human's decision points.

This document supersedes the draft proposal at `plugins/shipyard/shipyard.md`.

---

## Architecture (decided)

- **Product plugin.** `plugins/shipyard/`, versioned for standalone
  publication (ADR-0036 test 3). Skills live in-plugin, not in the repo-root
  skills library.
- **Five user-invoked skills, zero model invocation.** The four segments
  (`/scope`, `/shape`, `/spec`, `/ship`) plus a `/shipyard` router. Every
  skill sets `disable-model-invocation: true` (Claude Code); Codex ships an
  `agents/openai.yaml` sidecar with `allow_implicit_invocation: false`;
  opencode has no equivalent flag, so its descriptions are worded to demand
  explicit invocation (accepted gap).
- **Structural pauses.** No skill can fire a user-invoked skill, so a pause
  ends only when the human types the next segment. Each segment ends by naming
  the next command. Mid-segment escalations remain conversational and are the
  primary eval target.
- **One home for shared conventions.** The identical core (engagement
  ranking, escalate-on-surprise, time-boxed defaults, dual outputs) lives once
  in plugin `references/conventions.md`; each segment's pause contract is
  unique to it and stays inline in its skill.
- **Artifacts are tracked records.** Dual outputs land under `docs/`
  (ADR-0005: durable, human-facing); exact paths are build-time detail. The
  decision log stays prose, never a schema.
- **Generic execution seam.** Skill bodies name the capability, not a
  product: execution defaults to a single loop inline, and the human may hand
  the spec to an installed orchestration system instead. orchestrate is named
  only in shipyard's README.
- **Enter at any segment.** Each segment tolerates missing predecessor
  artifacts with an inline lite version of the predecessor's work. This is how
  the scaling rule is implemented.

---

## System conventions (shared across all four segments)

**The pause protocol.** Each skill ends at a named pause. Work stops there
until the human provides the unblocking input; in this architecture the stop
is structural, because only the human typing the next segment continues the
flow. Silence on stated assumptions is consent *inside* a skill, never
*across* a pause. An agent that treats a pause as passed on inferred approval
has failed the workflow regardless of output quality.

**Engagement cost ranking.** Every human interaction should be pushed as high
up this list as possible:
1. Default + veto ("assuming X unless you object by [time]")
2. Pick from scored options
3. Markup of an agent-drafted decision
4. One pointed question
5. Open-ended review (avoid)

**Escalate on surprise, not schedule.** No progress check-ins. Contact the
human mid-skill only when an assumption broke, options changed materially, or
an irreversible choice appeared that was not already approved.

**Time-box with defaults.** Every asynchronous escalation carries a deadline
and a default action so work never blocks silently. In an interactive session
the pause itself is the deadline.

**Scaling rule.** Low-stakes reversible work may enter at shape and ship only
(Pauses 2 and 4). High-stakes irreversible work walks all four segments.
Never fewer than two pauses. Segments make this possible by tolerating missing
predecessor artifacts: shape opens with an inline scope-lite when no problem
statement exists on disk, and ship verifies against whatever spec exists,
recording the thinner baseline in its delta report.

**Dual outputs.** Every skill produces its work artifact plus a decision log
(what was decided, by whom, asserted vs confirmed). The log is what makes the
workflow auditable and what downstream skills consume.

---

## Skill 0: shipyard (the router)

**Role:** concierge, not driver. Invoked to find your footing, not to do work.

### Frontmatter stub

```yaml
---
name: shipyard
description: "Report where work stands in the Shipyard flow and name the next segment to run"
disable-model-invocation: true
---
```

### What it steers

- Read the on-disk artifacts (problem statement, memo, specs, decision logs,
  delta report) and report position: which segments are done, which pause is
  open, what input the flow is waiting on
- Surface staleness: assumptions past their deadline, an unreturned memo, a
  spec drifted from its memo
- Name the exact next command; recommend the entry segment for new work by
  stakes (the scaling rule)
- Never execute a segment; it structurally cannot (user-invoked skills are
  not reachable from another skill)

Menu note: the plugin-prefixed listing reads `shipyard:shipyard`; the stutter
is accepted because unique names resolve bare, so `/shipyard` works.

---

## Skill 1: scope

**Segment:** intake and discovery. Turn a raw ask into a confirmed problem.

### Frontmatter stub

```yaml
---
name: scope
description: "Shipyard segment 1: turn a raw ask into a confirmed problem statement"
disable-model-invocation: true
---
```

### What it steers

- Establish the problem: who has it, what is true today, what success looks like
- Document current state from research (systems, docs, data), not only from the human
- Draw the scope boundary: explicitly in and explicitly out
- Surface assumptions inline as they form, each with a stated default

### Human interface

- **Mechanic:** assert and let the human correct. "I'm treating this as X
  affecting Y, scoped to Z. Wrong anywhere?" Never interview with question
  lists; correcting is roughly 5x faster than answering.
- **Budget:** at most one disconfirmation question, the single fact that would
  most change the framing.
- **Pause 1 (exit):** human confirms "this is the right problem." Roughly a
  two-minute read. This is the cheapest kill point in the flow; alignment cost
  concentrates here, and time invested here is repaid downstream at multiples.
  Ends by naming the next command: `/shape`.

### Output

Problem statement, current state summary, assumption register, scope boundary.
Confirmed, this becomes shape's input.

### Grounding references

- BABOK (IIBA): elicitation, current-state analysis
- TOGAF ADM Phases A/B: baseline (as-is) documentation
- Lean Six Sigma Define: problem statement and scope discipline (project charter, SIPOC)
- Hypothesis-driven framing in the McKinsey/MECE tradition

---

## Skill 2: shape

**Segment:** options and direction. Define where we're going and how we could
get there, then force an explicit human commitment.

### Frontmatter stub

```yaml
---
name: shape
description: "Shipyard segment 2: score directions and force the commitment memo"
disable-model-invocation: true
---
```

### What it steers

- Define desired state; assess the gap against the current-state baseline
  (when no confirmed problem statement exists on disk, open with an inline
  scope-lite and mark its assertions in the decision log)
- Generate genuine alternatives, always including "do nothing" and "defer"
- Keep options at solution altitude (build vs buy, approach A vs B). If schema
  or vendor-API debates start here, the skill is specing too early
- Score options as deltas from the accepted baseline on cost, risk, fit,
  effort, crediting controls that already exist; show score drivers, not the
  full matrix
- Draft the decision memo containing only decisions that belong to the human,
  pre-filled with recommendations, and phrased so the memo pasted back
  verbatim, marked up, is complete and actionable feedback

### Human interface

- **Mechanic:** expose the pivot, not the math. "Option B wins unless data
  residency outweighs cost. Does it?"
- **One pre-mortem prompt:** "Which option would you be embarrassed to have
  picked in 12 months?"
- **Pause 2 (exit):** human returns the marked-up memo: pick, modify, reject,
  or defer. This is the commitment event, the only structurally required human
  decision in the system, and the last cheap exit. Roughly five minutes. Ends
  by naming the next command: `/spec`.

### Output

Gap assessment, scored options with recommendation, and the returned memo.
Post-memo, ownership transfers: the human owns the decisions, downstream
skills specify those choices.

### Grounding references

- DoD Analysis of Alternatives handbook; OMB Circular A-94: options-scoring discipline
- Kepner-Tregoe Decision Analysis: weighted criteria, must/want separation
- Military decision brief and COA development: BLUF, courses of action, recommendation
- PRINCE2 Business Case theme: the "why" as a living, owned artifact
- Amazon PR/FAQ and 6-pager: anticipated-concerns FAQ, decision-ready narrative

---

## Skill 3: spec

**Segment:** requirements and design. Convert the committed direction into
something build-ready and testable.

### Frontmatter stub

```yaml
---
name: spec
description: "Shipyard segment 3: turn the committed direction into testable requirements and a build spec"
disable-model-invocation: true
---
```

### What it steers

- Derive functional and non-functional requirements from the memo decisions;
  every requirement testable, prioritized (MoSCoW), and traceable
- Produce the build spec: architecture, design decisions with rationale,
  implementation plan
- Triage every design decision as one-way or two-way door
- Two-way doors: decide, record in the decision log, move on. The human never
  sees these unless something breaks
- One-way doors: escalate as they are hit, not batched, each with a default
  and a deadline ("schema decision, reversible until Thursday, going with X")

### Human interface

- **Mechanic:** the human sees two to four decisions out of dozens. Most agent
  workflows over-engage exactly here; the skill's job is suppressing that.
- **Escalation triggers (only two):** material gaps discovered in scope/shape
  output, and one-way doors not already covered by the memo. Nothing else
  escalates.
- **Pause 3 (exit):** human approves the one-way doors. Roughly two minutes.
  Last point where changing course costs an edit instead of a rebuild. Ends by
  naming the next command: `/ship`.

### Output

Requirements spec and build spec. The requirements spec is the only artifact
consumed twice (built against, then verified against), making it the
highest-leverage document in the flow.

### Grounding references

- ISO/IEC/IEEE 29148 (successor to IEEE 830): requirements engineering, verifiability
- BABOK: traceability and MoSCoW prioritization
- ISO/IEC/IEEE 42010; TOGAF ADM Phases C/D: architecture description
- Architecture Decision Records (Nygard format): lightweight rationale capture, natural fit for the decision log
- Amazon one-way / two-way door framing: the irreversibility triage itself

---

## Skill 4: ship

**Segment:** build, verify, deliver. Build against the spec, verify
independently, get explicit acceptance, ship.

### Frontmatter stub

```yaml
---
name: ship
description: "Shipyard segment 4: build to spec, verify independently, deliver on explicit acceptance"
disable-model-invocation: true
---
```

### What it steers

- Execution engine is the human's choice at entry: the default is a single
  loop here; when an orchestration system is installed, the human may hand it
  the spec instead. Never stop or fail because a named capability is absent
- Build against the spec; record as-built deviations as they occur
- Verify against the requirements spec, independently of the build path where
  possible (fresh-context verification)
- Report exceptions against requirements, never coverage statistics
- Produce the delta report: everything that differs from what was approved at
  Pauses 2 and 3. Zero deltas is one line
- Escalate material issues mid-build as well-formed decisions (options with a
  recommendation and default), not as problems

### Human interface

- **Mechanic:** sign-off framed by blast radius. Low and reversible: "shipping
  at 2pm unless stopped." High or irreversible: explicit yes required.
- **Pause 4 (exit):** acceptance. Roughly a one-minute read when upstream was
  done well. Acceptance transfers ownership and knowingly accepts residual
  defects; it does not assert there are none. Nothing leaves the sandbox on
  inferred approval.

### Output

The shipped thing, verification results, delta report, sign-off record. A
brief post-ship note (what was learned, what to change upstream) closes the
loop back to scope.

### Grounding references

- ISO/IEC/IEEE 29119 (successor to IEEE 829): test planning and documentation
- ITIL 4: service validation and testing, change enablement, release management
- Google SRE launch checklists / Operational Readiness Review: production-entry criteria
- PMBOK Validate Scope: formal acceptance as ownership and risk transfer
- DORA / Accelerate: progressive delivery, small batches, pilot-as-acceptance

---

## Relationship to playbooks' assignment

assignment is a compressed one-shot of this method: memo gate (Pause 2) plus
acceptance and delta report (Pause 4) in a single invocation. After shipyard
lands, three proven pieces of its wording are salvaged (the copyable-memo
contract into shape, baseline-delta scoring into shape, the
never-fail-if-absent formula into ship), then assignment retires; the
playbooks README row and ADR-0036's illustrative sentence update at that
time. Sequenced this way so no gap opens.

---

## Authoring notes for the skill implementations

- These are discipline-enforcing skills, so author them TDD-style against
  failure cases first (the writing-skills methodology), then measure and
  iterate with skill-creator. The failure cases to test against are known:
  over-asking in scope, altitude drift in shape, over-escalation in spec,
  self-declared done in ship.
- Cross-segment pause integrity is structural by architecture, so evals target
  mid-segment discipline instead: unauthorized irreversible actions,
  silence-as-consent inside a segment, escalations arriving without options
  and a default.
- Descriptions are human-facing one-liners: with `disable-model-invocation`
  set, the description is menu help, not a model trigger. Trigger wording
  matters only for opencode, which lacks the flag; word those descriptions to
  demand explicit invocation.
- Each skill reads its predecessor's dual outputs (artifact + decision log)
  from disk rather than the conversation, so the chain works across sessions
  and across harnesses, and the router can locate position the same way.
