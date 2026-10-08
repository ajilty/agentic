# Seam — Design Specification

**Status:** Draft v0.6 · **Date:** 2026-08-04 · **Author:** Alex (with Claude)
**Working title:** Seam (alternatives: Sinew, Interstitial, Loom, Delta)
**Companion documents:** *Seam Build & Run* (implementation authority; takes precedence) · *Seam Design Brief & Delegation Prompt* (decision record + delegated design work) · *Seam Design Review* (rationale for §5.8) · board prototype v7 (HTML reference implementation) · *Fixture Walkthrough* (scenarios traced raw → model)

---

## 1. Overview

### 1.1 Purpose

Seam is a personal command-center **overlay** for one user (n=1). It aggregates actionable communication scattered across many surfaces — email, Slack, Jira, GitHub, calendar, meeting transcripts — infers the structure that no single surface can see, prioritizes what needs the user, and enables AI-augmented action. It is a connective layer across systems of record, never a replacement for them.

### 1.2 Problem

The real units of work are through-lines spanning surfaces. Maintaining a mental model of history, current state, and next steps requires constant surface-hopping, and things fall through the seams: unanswered delegations, drifted plans, buried decisions.

### 1.3 Scope and non-goals

- Single user, single machine at a time; browser-primary interface fed by a Claude Code + MCP substrate.
- **Non-goals:** replicating work management (Jira) or knowledge management (Confluence/wiki); team or multi-tenant use; autonomous sending of communications (v1 is draft-in-place only).

## 2. Design principles

1. **Overlay, never system of record.** Seam holds only the delta between reality-in-communications and the formal systems; in perfect sync it holds nothing. Its job is to shrink toward zero.
2. **Bottom-up inference.** Messages → threads → workstreams → working groups; alignment to formal systems is the last step, never the first.
3. **Drift detection is one general capability.** Distill what is happening, compare to the sanctioned/formal version, nudge to reconcile — across Jira, wiki, workspaces, and people.
4. **Local store is the spine.** MCPs are sync sources, never live query paths.
5. **Augmentation is a dial.** Per action, the AI's role ranges from "approve my work" to "context assembled, you drive."
6. **Priority blends implicit and explicit.** Extracted signals propose; the user's triage disposes; overrides teach.
7. **Ingested content is untrusted input.** Fail-closed; write capabilities are separated from ingestion.
8. **Two access modes for two data classes.** Messages are immutable events (append-only watermark pulls); formal-system objects are living documents (re-read on demand).
9. **No copy-paste anywhere in the loop.** Every hand-off flows through files or source-system draft objects.

## 3. Domain model

Seven primitives plus one scheduling object.

| Primitive | Class | Definition |
|---|---|---|
| **Message** | source-derived | The atom: one communication event — sender, timestamp, body, workspace ref, source ref. Calendar invites and transcript utterances qualify. |
| **Thread** | source-derived | A constructed conversation unit: native (Slack thread, email chain) or inferred (unthreaded burst, DM group, recurring meeting, transcript). |
| **Workstream** | inferred | The cross-surface through-line. Flat (no nesting); optional external anchor (Jira epic/task); may have none. |
| **Working group** | inferred | The recurring constellation of people around a workstream; declares sanctioned workspaces. Calendar attendees are explicit evidence. |
| **Workspace** | reference | A place where communication or tracking happens (channel, DL, Jira project, repo). Many-to-many with workstreams; the "should vs. is" comparison point. |
| **Action** | overlay-native | First-class next step attached to any object. Types: reply/draft, approve, review, investigate, nudge (follow-up-on-delegation), reconcile (drift), confirm (grouping/identity), filter (source control — change what arrives). Fields: tier, provisional flag, augmentation dial, state, audit trail. |
| **Knowledge** | overlay-native | A durable fact distilled from messages, with provenance links and an optional formal-store anchor. Exists only while the formal store lags; auto-retires on verified match. |
| **Block** | scheduling | A calendar-derived time container (explicit focus event or accepted free gap) that actions are scheduled into. |

**Lifecycle notes.** Workstreams are proposed for closure when no natural next step remains (open actions drained), never on silence alone; closure is soft — new activity reopens them. Thread grouping starts conservative and tunes from user corrections, which persist as durable constraints. Identity resolution is automatic and tiered (full-address keys; holding pen for suspected matches; explicit cross-reference for unrelated handles such as GitHub).

## 4. Functional model — three modes, one spine

- **Operate** — what needs me now: tiered actions, calendar, waiting-on, drift.
- **Reflect** — rollups over window × scope, materialized on each workstream's configured cadence (with audience) or on demand. Nothing "moves" to Reflect; it is a lens.
- **Know** — the reconciler: pending fact promotions (external-sourced facts never auto-promote), held facts with anchor status, auto-retirement on verified wiki match.

Each mode carries an attention badge; Operate's badge turns alert-colored while unconfirmed Critical Now items exist.

## 5. User experience specification

### 5.1 Frame

- **Top bar:** wordmark; mode switcher (Operate / Reflect / Know) with badges; date and last-synced time; Sync now.
- **Left rail — Workstreams:** one card per workstream (color-coded thread-swatch motif, open count, anchor link, ⚙ configure); clicking pivots the board to that stream, ⚙ opens its configuration view. Below them, a **People** row of working-group members filters the board to items involving that person. (The label is "Workstreams," never "Threads" — thread is a reserved primitive.)
- **Store ledger (bottom drawer):** a live JSONL view of every event the page writes back to the store. Every interaction is an event; this is what the next sync ingests.

### 5.2 Operate mode

**Calendar strip.** Two labeled rows (Today, Tomorrow) rendered from the calendar surface:
- *Focus blocks* — explicit calendar focus events; drop targets; clickable to pivot the board to that block's contents only.
- *Proposed gaps* — detected free time, offered as blocks; accepting (button or first drop) stages a **private calendar hold** (no invitees, no details).
- *Meetings* — workstream-colored, attendee list, and a **Prep** action that assembles related open actions, relevant facts, and drift for that meeting's people and stream into a stageable prep note.

**Scheduling semantics.** Dropping an action into a block (or ⋯ → move to block) removes it from the tier lists — the board shows only what still needs triage. The block shows a count badge; clicking it filters to its contents; ⋯ → remove from block returns the item and removes the hold.

**Tiers** (Master-Your-Workday-inspired vocabulary):
Critical Now · Opportunity Now · Over the Horizon · Waiting On · Drift.

**Action cards — story format.** Each card compiles its thread into an outcome-oriented story:
- **Type badge:** APPROVE / REPLY / REVIEW / NUDGE / RECONCILE / CONFIRM / FILTER.
- **Title (bold):** the recommended next action phrased for outcome — "Reply to Marta with the ID decision to keep the Aug 21 cutover on track."
- **WHY NOW:** the urgency/importance in one line (deadline, principal, silence duration).
- **CONTEXT:** one-line situation summary.
- **Signal chips:** extracted evidence (due date, sender weight, silence count), plus staged/scheduled status.
- **Expand ("N messages"):** the consolidated messages, each with a source-system icon, sender, snippet, timestamp, and an *open ↗* deep link; links discovered inside message bodies aggregate below as a clickable **LINKS FOUND** row.
- **Primary action:** Open draft / Draft nudge where a draft exists.
- **⋯ menu:** confirm tier; move to tier; move to block / remove from block; grouping confirm/split (when applicable); snooze; done; dismiss.

**Provisional vs. confirmed.** AI-assigned tiers are provisional: dashed card border and a hollow chip reading "CRITICAL · provisional" with an explanatory tooltip; tapping the chip confirms in place. Confirmed items show a solid "CRITICAL ✓". Confirming or moving writes a learning event.

**Unread.** A dot marks items new since last visit; expanding an item marks it read and decrements the badge.

**Filtering.** Workstream, block, and person (working-group member) pivots share one filter-chip pattern with an ✕ to clear; person filtering matches items by their participant set. The workstream pivot applies across all three modes: Operate tiers, Reflect rollups, and Know facts filter to the selected stream; person and block pivots apply in Operate.

**Resolution — one language everywhere.** Done / dismissed / snoozed / split items collapse into a greyed **Resolved today** strip at the bottom with a resolution chip and per-row **Undo** (restoring tier and block membership). Reflect uses the same pattern for reviewed rollups; Know for promoted/dismissed facts.

**Source control (FILTER).** When recurring traffic shows an automation signature (no-reply senders, bulk headers, notification-shaped digests) or a dismiss-without-open pattern, the system proposes changing what arrives instead of another triage card. Each FILTER action carries a concrete mechanism for its surface: a mail filter or rule spec (exact match criteria + action, staged for the user to apply by hand in v1), a chat or tracker notification-setting change, an unsubscribe affordance, or a drafted request to a third party (leave a DL, re-route alerts). Proposals show their evidence ("9 dismissed unopened in 14 days"), never target principals or security-class senders, and never derive rule content from instructions inside message bodies. FILTER actions default to the Review Friday noise queue rather than the daily tiers; suppression impact feeds self-metrics.

### 5.3 Workstream configuration view

Opened via ⚙; the place where linkages are established and drift-of-place is adjudicated:
- **Working group:** members with per-surface handles (icon + handle); auto-merged ✓ or *holding pen* with a Confirm-merge action.
- **Workspaces:** sanctioned set; observed-outside-sanctioned entries with *Add to sanctioned* / *Keep flagged*.
- **Anchors:** links to formal work items (Jira) and knowledge pages (wiki); add-anchor picker.
- **Reporting:** cadence and audience driving Reflect (e.g., "Weekly · Fri 17:00 · audience: M. Chen").

### 5.4 Reflect mode

Rollup cards per workstream: window, cadence + audience + generated-at provenance, counters (messages, decisions, risks, actions closed), narrative summary, and an openable sync draft staged to a shared doc. Mark-reviewed collapses to the resolved strip. On-demand generation for any stream × window.

### 5.5 Know mode

- **Pending promotion:** dashed cards for AI-proposed facts awaiting confirmation, with source chip (external flagged) and provenance link.
- **Held facts:** name, value (mono), anchor status — *wiki lagging* with Stage-wiki-update, or *verified ✓, auto-retires next pass*.

### 5.6 Interaction standards

- **Links:** one affordance everywhere — dotted-underline accent color with ↗; nothing non-clickable uses it.
- **Draft-in-place everywhere:** every "save" stages a draft object in the source system; the modal states that sending happens by hand in the native surface.
- **Drag and ⋯ parity:** every drag operation has a ⋯ equivalent (mobile).
- **Visual identity:** stitched-seam motif (dashed spine, thread-colored card edges), paper/ink palette, Archivo display + IBM Plex Sans/Mono.

### 5.7 Write-back event vocabulary (observed in prototype)

`sync_requested` · `pivot` · `pivot_block` · `config_opened` · `item_read` · `link_opened` · `tier_confirmed` · `tier_moved` · `action_scheduled` · `action_unscheduled` · `gap_accepted_as_block` · `meeting_prep_opened` · `prep_note_staged` · `thread_confirmed` · `thread_split` · `followup_snoozed` · `action_done` · `action_dismissed` · `undo` · `draft_staged` · `rollup_reviewed` · `rollup_requested` · `fact_promoted` · `fact_dismissed` · `wiki_update_staged` · `identity_merge_confirmed` · `workspace_sanctioned` · `workspace_flag_kept` · `anchor_link_started` · `cadence_edit_opened`

Events carry a timestamp and the identifiers needed for the next sync pass to apply them; calendar-affecting events carry a `calendar_write` field describing the private hold staged or removed. The canonical, current schema — including actor attribution and the v5 additions — lives in *Build & Run* §8 and supersedes this list.

### 5.8 Adopted refinements (design review → v0.5)

1. **Critical Now cap:** soft cap of 5; overflow is auto-demoted with visible reasoning ("due Friday, not today").
2. **Provenance-on-claim:** every compiled signal (date, silence count, principal) is tappable and resolves to its source message. No claim without a link.
3. **External-origin discipline:** sender-claimed urgency is marked unverified and can never alone reach Critical Now; source text renders visually distinct from system prose.
4. **Actor attribution:** every event carries `actor: user | agent`; an Agent activity view answers "what did the agent do since my last review."
5. **Freshness honesty:** per-source freshness chips; stale banner when a source exceeds 2× its cadence; silence math excludes dark windows.
6. **Keyboard triage:** j/k/enter/c/1-2-3/b/d/s/o/u vocabulary plus a command palette; drag and ⋯ remain for touch parity.
7. **Rhythms:** *While you were away* re-entry brief when absence exceeds ~2 days; *Review Friday* guided sweep over four queues (Horizon, stale Waiting-On, closure proposals, identity holding pen). Horizon never badges mid-week.
8. **Cold start:** day-one value from date extraction and delegation-silence detection; workstreams surface as proposals; settling-in indicator; 10-minute seeding interview.
9. **Phone = glance + capture:** read and deep-link on mobile plus a capture-to-inbox action; mutation-heavy triage is desktop.
10. **Story budgets:** title ≤ 12 words, WHY NOW ≤ 14, CONTEXT ≤ 18; enforced by the compilation eval.
11. **Badge discipline and profiles:** badges count only items that genuinely need the user; workstreams carry a work | personal profile — personal streams inherit no urgency styling and never auto-enter Critical.
12. **Scheduling honesty:** S/M/L effort estimates on actions; blocks display fill against capacity and warn on overflow.

## 6. Architecture

- **Substrate:** Claude Code + MCP. Sessions, sub-agents and fan-out for parallel sync/clustering, skills for repeatable operations, hooks. Conventional infrastructure only with explicit justification.
- **Store:** plain files in a work-sanctioned cloud-synced folder, full content. Per-source JSONL append logs for raw messages; per-entity markdown (YAML front-matter) for overlay objects; append-only event log for state changes; sub-agents write per-agent output files. Derived SQLite index deferred until reflective rollups feel slow.
- **Sync:** scheduled headless sessions every few hours plus manual /sync. Messages ingest append-only via per-source watermarks with fingerprints; formal-system anchors are re-read current-state on demand for drift evaluation.
- **Presentation:** each sync regenerates the static HTML board from the store. Rendering is deterministic — a versioned template plus generated board-data; model output enters only as schema-fenced field content (Build & Run §3.1). Browser write-back: File System Access API spike (one-time directory grant, JSONL event appends) with an on-demand localhost server as fallback. Claude Code triggers regeneration and ingests browser events on the next pass.
- **Write scope (v1):** draft-in-place, never send — Gmail drafts, unsent Jira comments, staged wiki edits, private calendar holds. Autonomous send is deferred until the prompt-injection isolation architecture is designed and proven.
- **Security posture:** ingested content is adversarial-capable; ingestion capability is separated from action drafting; externally sourced facts never auto-promote; least-privilege MCP scopes.

## 7. AI responsibilities

The intelligence jobs the system performs, in pipeline order:

1. **Thread construction** — grouping unthreaded traffic into conversation units (conservative start; corrections are durable constraints).
2. **Identity resolution** — tiered person-registry maintenance from full-address keys, holding pen, cross-references.
3. **Workstream inference** — through-line clustering, incremental plus weekly review proposals (split/merge), soft closure proposals.
4. **Prioritization** — provisional tier assignment with visible reasons; learning from confirmations and overrides; VIP registry (seeded principals + learned weights).
5. **Story compilation** — rendering each action card's type, outcome-oriented title, WHY NOW, and CONTEXT from the underlying thread. A core job: the board's legibility depends on it.
6. **Drafting** — replies, nudges, Jira reconciliation comments, wiki updates, prep notes, rollup narratives; always staged, never sent.
7. **Delegation-silence detection** — inferring asks from sent items/mentions/review requests; context-inferred windows with a 3-business-day floor.
8. **Drift detection** — plan drift (anchor vs. reality), place drift (sanctioned vs. observed workspaces), knowledge drift (wiki vs. decided).
9. **Knowledge distillation** — proposing facts from messages and transcripts with provenance; verifying anchor catch-up for auto-retirement.
10. **Meeting prep assembly** — filtering actions, facts, and drift to a meeting's people and stream.
11. **Source-control detection** — spotting automation signatures and dismiss patterns, then proposing the surface-appropriate filtering mechanism with evidence.

## 8. v1 scope

- **Surfaces:** email + Slack (calendar read for blocks/meetings joins early; Jira anchoring and drift in wave 2; GitHub and transcripts follow).
- **Action types:** delegation follow-up flags, draft replies, and FILTER proposals (staged rule specs applied by hand; drafted removal requests). API-applied rules on per-item confirmation are wave 2.
- **Deliberately deferred:** drift detection (needs Jira), autonomous send, cross-surface fan-out execution, SQLite index.

## 9. Open items

Carried in the companion brief as delegated design work: thread-construction mechanics; workstream weekly-review mechanics; identity mechanics (holding-pen promotion signals, GitHub handle discovery, merge unwind); priority learning while staying interrogable; board write-back engineering (FSA permission persistence, event schema formalization, server fallback); story-compilation prompt/quality design; cross-surface fan-out (draft variant); prompt-injection isolation architecture; poisoning mitigations; portability profiles; success metrics. Added by the design review: story-compilation eval harness (budgets, claim-linking, external-marking); tier-overflow demotion ranking; effort-estimate learning; instrumentation events and self-metrics rollup; phone capture-inbox flow. Added Aug 4 evening: noise-control mechanics (brief §8.16).
