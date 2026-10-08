# Seam — Design Brief & Delegation Prompt

*Working title; naming candidates in §10. Drafted 2026-08-04 from a voice ideation session; updated same day after two working sessions. All user-facing decisions are now made (§7); what remains (§8) is design work within fixed postures.*

## How to use this document

A *Build & Run* document now exists and holds implementation precedence; this brief remains the decision record and the mechanics-delegation list. Design Spec v0.5 §5.8 records twelve further refinements adopted from a design review, and prototyping rounds settled the additional decisions summarized at the end of §7.

You are a reasoning model being handed this brief for a deep design pass. Treat §1–§7 as settled context — §7 records decisions already made; do not relitigate them unless you find a genuine flaw, in which case flag it explicitly rather than silently overriding. Your job is §8: most items have a fixed posture — design the mechanics within it. Where an item is genuinely open, propose 2–3 options with trade-offs and a recommendation. Then propose a sequenced plan (§9 is a starting sketch — improve it).

**Hard constraint to respect throughout:** the substrate is Claude Code + MCP (§6). Do not reflexively reach for message queues, object stores, standing services, or bespoke deterministic APIs. Conventional infrastructure requires explicit justification that the harness genuinely cannot stretch to cover the need.

## 1. Problem

One person — a senior security leader — receives actionable communication across many surfaces: Jira tickets, comments, and mentions; Slack channels, threads, and DMs; email (Outlook/Gmail) inboxes plus sent items awaiting replies; GitHub PRs, review requests, and code comments; calendar invites; meeting transcripts and notes. The real units of work are through-lines that span these surfaces, but no single surface can see them. Maintaining a mental model of history, current state, and next steps requires constant surface-hopping, and things fall through the seams: unanswered delegations, drifted plans, buried decisions.

The system is a personal command center overlay for one user (n=1, not a team product): aggregate the mess, infer the structure, prioritize what needs the user, and enable AI-augmented action — without becoming another system of record.

## 2. Design principles (settled)

1. **Overlay, never system of record.** Do not replicate work management (Jira) or knowledge management (Confluence/wiki). The overlay holds only the *delta* between reality-in-communications and the formal systems. In perfect sync it holds nothing of its own; its job is to shrink toward zero.
2. **Bottom-up inference.** Structure emerges from the mess: messages → threads → workstreams → working groups. Alignment to formal systems is the *last* step of the pipeline, never the starting point.
3. **Drift detection is one general capability, not a per-system feature.** The same shape recurs everywhere: distill what is actually happening, compare against the sanctioned/formal version, nudge to reconcile — and, where safe, auto-propose the update. Applies to Jira (plan vs. reality), the wiki (documented vs. decided), workspaces (sanctioned channels vs. where conversation actually happens), and people (declared group vs. who actually shows up).
4. **Local store is the spine.** MCP access is expensive and rate-limited; the presentation layer never queries sources live. Sources sync into the store; every item carries a source reference, a last-synced timestamp, and a fingerprint for cheap change detection.
5. **Augmentation is a dial, not a switch.** Per action, the AI's role ranges from "I've got this — just approve" to fully manual with context assembled. The dial setting is part of the action object.
6. **Priority blends implicit and explicit.** Implicit: extracted dates and urgency, sender weighting (bosses, regulators, VIPs one cannot keep waiting). Explicit: the user's own triage (must/should/could × today/tomorrow/someday). Neither alone is sufficient.
7. **Ingested content is untrusted input.** The system moves external, adversarial-capable text (email, Slack from outside parties) toward agents that hold write capabilities. Fail-closed posture throughout; see §8.
8. **Two access modes for two data classes.** Messages are events — effectively immutable minutes after they're sent — and ingest append-only via watermark pulls. Formal-system objects (Jira issue bodies, wiki pages, documents) are living documents and are re-read current-state on demand whenever drift is evaluated. The overlay never builds a general delta engine; the split makes one unnecessary.
9. **No copy-paste anywhere in the loop.** Every hand-off — triage input, drafted replies, browser feedback — flows through files or source-system objects that the harness and the user can both reach directly.

## 3. Data model — seven primitives

**Source-derived**

- **Message** — the atom. One communication event from one surface: sender, timestamp, body, workspace reference, and a source reference sufficient to link back and detect change. Calendar invites qualify (sender, participants, body), as do individual transcript utterances (speaker + timestamp).
- **Thread** — a *constructed* conversation unit, not a trusted native grouping. Sometimes it maps 1:1 to a native Slack thread or email chain; sometimes it is inferred from unthreaded channel bursts (same participants, tight time window, topical continuity) or from a DM group. A recurring meeting (an invite plus its updates) is a thread; a meeting transcript is a thread of utterances. Threading is itself a clustering problem.

**Inferred**

- **Workstream** — the through-line spanning surfaces; the core inferred object. Deliberately flat — no nesting. Scope hierarchy (project/epic/task) belongs to the formal system; the workstream carries an *optional external anchor* (e.g., a Jira epic or task) and may legitimately have none (personal projects).
- **Working group** — the ad hoc constellation of people who keep recurring around a workstream; distinct from standing teams. Declares its *expected (sanctioned) workspaces*. Calendar attendee lists are explicit evidence for this object, corroborating constellations inferred from message traffic.

**Reference**

- **Workspace** — a lightweight reference to a place where communication or tracking happens: a Slack channel, a distribution list, a Jira project, a board, a GitHub repo. Many-to-many with workstreams. The comparison point between "should" (sanctioned by the working group) and "is" (where messages actually originate).

**Overlay-native**

- **Action** — first-class, attachable to any of the above. Types: draft/send communication (possibly fanning out across surfaces), approve, review, investigate (e.g., a security alert), follow-up-on-delegation (inferred from asked-and-silence), filter (source control over what arrives; §7). Fields: priority (implicit + explicit), state, augmentation-dial setting, audit trail.
- **Knowledge** — durable facts distilled from the transient message stream: tenant IDs, instance names, agreed policies, decisions. Carries provenance links back to originating message(s) and an *optional anchor* to a formal knowledge store (a Confluence/wiki page). Exists only while the formal store lags; retires once the anchor catches up. Promotion is AI-proposed, human-confirmed (at least initially). Hand-written meeting summaries enter here directly, provenance-linked to their calendar event; transcripts are distilled into facts with the transcript as provenance.

## 4. Functional model — three modes on one spine

**Operational** — the day-to-day command center: what needs me now, what is drifting, what is waiting on someone else. Reads open actions, drift signals, and priority.

**Reflective** — rollups over a time window × a scope: the weekly sync for a working group, the monthly update for a set of workstreams, the quarterly accomplished-and-next. Falls out of timestamps, workstream links, and action state history — no extra data entry.

**Knowledge** — the reconciler: accumulated context that makes automated actions accurate without re-supplying the same facts twice, plus nudges that push those facts into the formal store so the overlay can forget them.

## 5. Worked example (direction matters: bottom-up)

Raw traffic arrives: a Slack DM ("HR says Workday go-live slipped to Q3 — does that push our Okta cutover?"), an Outlook chain with the identity vendor about tenant migration, and unthreaded channel messages where two engineers argue about SCIM provisioning. The system groups each into threads, then notices the through-line — all touch Okta consolidation, and the same handful of people recur. That cluster becomes a candidate workstream; the recurring people become a candidate working group; only then does it look outward: "There's a Jira epic *IAM Unification* — anchor to it?" Drift then surfaces naturally: vendor decisions living in email that Jira doesn't reflect; conversation happening in a DM outside the sanctioned channel.

Two stress cases: a secure-SDLC improvement effort stresses thread inference (mostly unthreaded team-channel chatter) and fuzzy workstream boundaries (process work bleeds together); a solo homelab project (Ajilty, the user's separate agent-orchestration platform) stresses the no-anchor path — working group of one, no formal system, the overlay is the only tracking that exists.

## 6. Architecture constraint: Claude Code-native

The user's most powerful interface — and the one with inherent, already-permitted connectivity to the third-party systems, especially at work — is Claude Code with MCP servers. Early versions should therefore be built from harness primitives: sessions, sub-agents and fan-out for parallel sync and clustering, skills for repeatable operations, hooks, local files as storage, MCP for all source access. The presentation layer is browser-based: sync regenerates a static HTML board, and the browser writes triage events back into the store (§7). The user has prior context on MCP gateway/aggregation patterns (MetaMCP) and multi-agent orchestration. Conventional infrastructure (databases-as-services, queues, standing daemons, bespoke APIs) is a last resort requiring explicit justification. Architecture beyond this constraint is deliberately open — that openness is what §8 should resolve.

## 7. Decisions from working sessions (2026-08-04)

**Store.** Plain files in a cloud-synced folder — no git, no database. Residency: a work-sanctioned cloud, full content. Rationale: volume is a few hundred messages per day (low tens of thousands of items per year); a single writer on one machine at a time, so no conflict machinery; files are maximally harness-native. Layout: per-source JSONL append logs for raw messages (high volume, machine-read, watermark-friendly) and per-entity markdown files for overlay objects — one file per workstream, knowledge facts as markdown with YAML front-matter — since those are what the user and agents actually read and what the browser renders. Overlay state changes (action transitions, closures, reopenings) are written append-only as an event log, giving history without version control. Fanned-out sub-agents each write to their own output file, never a shared one. A derived SQLite index for reflective-mode rollups is the acknowledged migration path — built when rollups actually feel slow, not preemptively.

**Sync.** Two access modes, not a delta engine:

- *Messages are events.* In practice immutable — people edit within moments of sending, which the polling cadence absorbs. Ingest append-only via a per-source watermark (high-water timestamp or ID), fingerprinting each item so re-encounters resolve in one comparison. Email is near-pure append-only; Slack's edit/delete churn is early and cosmetic; no retroactive sweep is needed.
- *Formal-system objects are living documents.* Jira issue names and bodies, wiki pages, and documents get revised weeks later — and they are precisely what drift is measured against. They are never watermarked; current state is re-fetched on demand whenever drift is evaluated for a workstream.

Trigger: scheduled headless Claude Code sessions every few hours, plus a manual /sync command for on-demand freshness before a triage session.

**Identity resolution.** Automatic, tiered, full-address keys. A person registry derived over time from the data itself, not hand-curated. The org is multi-affiliate: the same first.last local part exists at different domains and may be different people — or one person straddling affiliates — so the join key is always the full email address, never the local part alone. Merging runs on confidence tiers: (a) a full email match across surface profiles auto-merges; (b) the same display name at a different domain is held as separate-but-suspected in a holding pen, merged only on corroborating evidence (e.g., interchangeable appearance in the same workstream) or a one-time confirmation — never on name alone; (c) unrelated handles, notably GitHub, link only via explicit cross-reference (a GitHub handle listed in a Slack profile, a commit email). Scale is bounded — dozens of recurring people.

**Inference posture.** Thread merging for unthreaded traffic starts conservative — merge only on strong signals (same participants, tight window, clear continuity) — and tunes over time from the user's corrections, which persist as durable constraints. Fragmented threads are cheap because workstream clustering reconnects the pieces; false merges can bury a high-priority message. Workstream assignment is incremental at each sync, plus a weekly review pass that proposes splits and merges for confirmation — never a full re-cluster, because workstream identity must stay stable (actions and knowledge hang off it). Closure: a workstream is proposed for closure when it has no natural next step — open actions drained, nothing pending — not on silence alone. Closure is soft: new activity clustering to a closed workstream reopens it automatically.

**Prioritization.** No opaque score. Every item carries a visible tier from the must/should/could × today/tomorrow/someday grid, with reasons shown ("regulator sender, date extracted"). The AI assigns a provisional tier so the morning view arrives pre-sorted; provisional is visually distinct from confirmed; user overrides feed back into sender weights. The VIP registry is seeded manually for the handful of principals (boss, regulators) and learned from override behavior for everyone else.

**Operational surface.** Browser-primary. Each sync regenerates an HTML board/brief rendered from the store. The browser writes triage events (tier overrides, confirms, closures, draft approvals) back into the store with no copy-paste: spike the File System Access API first — a static page appending JSONL events into the store folder after a one-time directory grant (Chromium) — with an on-demand localhost server as the proven fallback. Claude Code triggers regeneration and ingests browser-written events on the next pass. Interactive triage sessions in Claude Code complement the board.

**Actions.** v1 write scope: **draft-in-place, never send.** The system creates draft objects inside the source systems — Gmail drafts, unsent Jira comments — and sending always happens by the user's hand in the native surface. Blast radius stays zero while the injection isolation (§8) is undesigned; autonomous send, even gated, is earned later. Delegation follow-up combines explicit waiting-on marks made during triage with asks inferred from sent items, mentions, and review requests; the AI infers the follow-up window per context with a floor of three business days.

**Source control (added Aug 4 evening).** A **FILTER** action type for automated notifications, spam, and other traffic where the right move is changing what arrives: the system proposes the surface-appropriate mechanism — a mail filter/rule spec (staged, user-applied in v1), a notification-setting change, an unsubscribe, or a drafted request to a third party (leave a DL, re-route alerts). Detection keys on automation signatures (no-reply senders, bulk headers) and dismiss-without-open patterns; proposals carry evidence, never target principals or security-class senders, never take rule content from message bodies, and queue to Review Friday rather than the daily tiers. API-applied rules (self-scoped, per-item confirmed) are wave 2.

**Knowledge.** Facts are markdown files with YAML front-matter — structured enough for agents to query mid-action, readable in the browser. Retirement is automatic on verified match: the system re-reads the anchor page, confirms the fact's content is present, logs an audit event, and drops the overlay copy — safe because verification is a read comparison and the event log preserves history. Poisoning posture: facts sourced from external senders never auto-promote.

**Surfaces.** Full ingestion set: email, Slack, Jira, GitHub (PRs, review requests, code comments — leans hardest on tier-(c) handle mapping), calendar (invites as messages; recurring meetings as threads; attendees as working-group evidence), and meeting transcripts/notes (a transcript is a thread of utterances feeding normal inference; hand-written summaries enter as knowledge directly; transcripts are expected to be the highest-yield promotion source).

**v1 slice.** Email + Slack first — where triage pain concentrates and the hard inference lives (unthreaded bursts, sent-item silence). Both v1 action types: delegation follow-up flags (read-only) and draft replies (draft-in-place). Drift detection via Jira anchoring is deliberately deferred to the second wave.

**Prototype-round decisions (same day, rounds 1–5).** Blocks are calendar-derived: explicit focus events plus detected free gaps offered for acceptance; scheduling an action stages a **private calendar hold** (no invitees) and removes the item from the tier lists; blocks are pivotable views with capacity fill from S/M/L effort estimates. Reflect materializes on **per-workstream cadence with a named audience** (configured in the workstream linkages view) plus on-demand. Tier vocabulary is MYN-inspired: Critical Now (cap 5) / Opportunity Now / Over the Horizon, plus Waiting On and Drift. Cards are **story-compiled**: type badge, outcome-oriented title, WHY NOW, CONTEXT, under word budgets, with provenance-linked claim chips. The board carries mode badges, workstream pivots, a per-stream configuration view (working group, workspaces, anchors, reporting), a consistent resolve-collapse-undo pattern, keyboard triage, and an actor-attributed event ledger. Review adoptions are recorded in Spec v0.5 §5.8.

## 8. Delegated design work

Postures are fixed where §7 speaks; design the mechanics within them. Where genuinely open, propose 2–3 options with trade-offs and a recommendation.

1. **Thread construction mechanics.** Within the conservative-start posture: the concrete signal set and thresholds for merging unthreaded traffic, and the representation of user corrections as durable constraints that tune future clustering.
2. **Workstream weekly review.** The split/merge proposal mechanics: what evidence triggers a proposal, how identity is preserved through a split or merge, and how the review is presented on the board.
3. **Identity mechanics.** Which corroboration signals promote a suspected match out of the holding pen, how tier-(c) cross-references are discovered for GitHub handles, and how a mistaken merge is detected and unwound after it has fed working-group inference.
4. **Priority learning.** How overrides adjust sender weights and tier assignment over time while every adjustment remains interrogable by the user.
5. **Board + write-back design.** The HTML board's information architecture for triage; the JSONL event schema the browser writes; File System Access API permission persistence across sessions; the on-demand server fallback spec; how Claude Code ingests browser events.
6. **Cross-surface fan-out (draft variant).** One intent producing drafts in multiple surfaces at once; partial-failure handling; how the user is shown the full set before sending any.
7. **Prompt injection isolation.** The big one. Ingested content is adversarial-capable and the system holds draft-write capabilities. Propose the isolation architecture: read-only ingestion agents, sanitization boundaries, capability separation between the layer that reads the mess and the layer that writes drafts, and what the user must see at review time for approval to be meaningful.
8. **Poisoning mitigations.** Beyond never-auto-promoting externally sourced facts: provenance display, confidence decay, contradiction detection between facts.
9. **Portability profiles.** The same design running in a work context (rich MCPs, hard constraints) and a personal one without forking: what varies by profile vs. what is core.
10. **Success metrics.** Concrete, measurable definitions for the v1 slice: missed-item rate, time-to-triage, follow-up catch rate — and how they're captured without extra ceremony.
11. **Story-compilation quality.** Prompt design and eval harness enforcing word budgets, claim→provenance linking, and external-content marking; failure taxonomy for miscompiled cards.
12. **Demotion ranking.** The algorithm that orders Critical Now overflow for auto-demotion and generates its visible reasoning.
13. **Effort-estimate learning.** How S/M/L proposals calibrate from actual completion patterns while staying correctable.
14. **Instrumentation.** Session-marker events and the self-metrics rollup (time-to-board-zero, nudge→reply conversion, drift closed) derived from the ledger.
15. **Capture-inbox flow.** Phone capture into the store inbox and its surfacing path into desktop triage.
16. **Noise-control mechanics.** Detection thresholds for automation signatures and dismiss patterns; the mechanism taxonomy per surface (own rule / setting change / unsubscribe / request-to-party); the rule-spec format the user applies by hand; injection-safety tests; measuring suppression impact; the wave-2 confirmed-apply path.

## 9. Next steps (starting sketch — refine)

1. Run this brief through the delegated model against §8; produce mechanics, options where open, and a revised plan.
2. Inventory the actually-available and permitted MCP servers for email and Slack (v1), then the remaining surfaces.
3. Spike 1: sync one v1 surface into the file store with watermarks and fingerprints; measure rate limits, latency, and token cost of a pull cycle.
4. Spike 2: File System Access API write-back proof of concept — static page, one-time grant, JSONL event append, permission persistence across browser restarts.
5. Build the v1 slice: email + Slack ingest → threads → provisional tiers → morning board → follow-up flags + draft replies.
6. Settle the name.

## 10. Naming

Working title **Seam** — the join between fabrics; short; literally "the connective bit." Alternatives: **Sinew**, **Interstitial**, **Loom** (weaving threads into fabric), **Delta** (the system that holds only the difference). Check for collisions before committing.
