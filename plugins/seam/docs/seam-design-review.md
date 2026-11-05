# Seam — Design Review

**Reviewing:** Design Specification v0.4 · **Date:** 2026-08-04
**Method:** the same design examined through ten lenses, each grounded in a persona-moment; findings carry concrete refinements. A prioritized change list closes the document.

---

## 0. Persona-moments

One user, but six distinct modes of that user, and the design must serve all of them:

- **P1 · 8am triage** — coffee, 90 seconds to a mental model, ten minutes to a triaged board.
- **P2 · The manager** — delegations out, follow-ups owed, reporting up to principals on cadence.
- **P3 · In-meeting / pre-meeting** — needs the right context in the 5 minutes before a call.
- **P4 · The returner** — back from 3 days out; the morning board alone is not a catch-up.
- **P5 · The builder, off-hours** — personal streams (Ajilty), different rhythm, no principals.
- **P6 · The auditor** — a CISO reviewing what his own AI-augmented system did and why. This persona is unusual and load-bearing: the user will hold this tool to the standard he holds vendors to.

---

## 1. Cold start & the first week

**Finding 1.1 — The spec assumes a warmed system.** Bottom-up inference needs traffic history; day one has zero workstreams, untrained tiers, an empty person registry. If the day-one board is noise, the habit never forms and nothing else matters.

**Refinement:** design the cold start explicitly. Two capabilities work at full strength with no inference: deadline/date extraction and delegation-silence detection from sent items. Day one leads with those — "these 4 things have dates; these 3 asks got no reply" is real value in hour one. Workstreams appear only as *proposals* as clusters form ("these 9 messages look like one effort — name it?"), and the UI is honest about its state: a "settling in" indicator replaces confident tiering until confirmation volume crosses a threshold.

**Finding 1.2 — Seeding is cheaper than inferring.** The user already knows his top workstreams, principals, and channels; making him wait for inference to rediscover them is waste.

**Refinement:** a 10-minute onboarding interview (in-session): name 3–5 workstreams, point at their channels and anchors, list principals. Inference then corroborates and extends rather than bootstrapping from nothing.

## 2. Triage ergonomics & cognitive load (P1)

**Finding 2.1 — Critical Now has no discipline.** MYN's core insight is that Critical Now only works when it is nearly empty. Nothing stops the AI from proposing twelve critical items on a bad day, at which point the tier means nothing.

**Refinement:** soft cap of 5. Above it, the system must rank and auto-demote with visible reasoning ("demoted: due date is Friday, not today"). Overflow is a signal to the priority model, not a rendering problem.

**Finding 2.2 — Mouse-only triage is slow for this user.** The persona lives in Ghostty and tmux; thirty ⋯-menu interactions a morning is friction he will resent.

**Refinement:** keyboard triage vocabulary — j/k navigate, enter expands, c confirms tier, 1/2/3 moves tier, b moves to block, d done, s snooze, o opens draft, u undo — plus a command palette. Drag and ⋯ remain for mobile parity.

**Finding 2.3 — Story format wins, but only if scannable.** Two labeled lines per card × 25 cards is a lot of reading if the prose meanders.

**Refinement:** hard budgets: title ≤ 12 words, WHY NOW ≤ 14, CONTEXT ≤ 18. Budget adherence becomes part of the story-compilation eval.

## 3. Trust, explainability & error recovery (P6)

**Finding 3.1 — Compiled claims aren't verifiable in place.** If WHY NOW says "due Wed Aug 6" and the extraction is wrong, the user acts wrongly. Trust in the compilation layer is earned claim by claim.

**Refinement:** provenance-on-claim — every extracted signal (date, silence count, principal) is tappable and jumps to the exact source message. The chips already gesture at this; make it a guarantee: no claim without a link.

**Finding 3.2 — Correction must be cheaper than the error.** A wrong tier costs one keystroke to fix (good). A wrong workstream assignment, wrong identity merge, or wrong thread grouping costs a trip to another view (bad).

**Refinement:** correction affordances live where the error is seen: ⋯ gains "wrong workstream →" and "not the same person" directly on cards; the config view remains the bulk-management surface.

## 4. Adversarial review (P6 — the CISO reads his own tool)

**Finding 4.1 — The aggregator is a social-engineering amplifier.** An external email saying "URGENT — approve today" gets faithfully compiled into an urgent-looking card with an APPROVE badge. Aggregation launders the origin of urgency: the board's authority transfers to attacker-supplied text.

**Refinement:** external-origin discipline in compilation. Urgency claims sourced solely from external senders are marked ("urgency claimed by sender — unverified") and can never *alone* place an item in Critical Now; internal corroboration (a date in Jira, a principal's message) is required. Source text is always visually distinct from system-generated prose.

**Finding 4.2 — The ledger doesn't say who acted.** "What did the AI stage while I was away?" is the first audit question and the current event schema can't answer it.

**Refinement:** every event carries `actor: user | agent`, and Operate gains an *Agent activity* audit view — drafts staged, facts proposed, tiers assigned since last review. Optional later: hash-chained event log for tamper evidence (likely overkill for n=1; note and park).

**Finding 4.3 — Rendering hygiene.** Message snippets and discovered links are attacker-supplied content rendered into a privileged UI. (Engineering note rather than design: strict escaping, no HTML from sources, link destinations shown on hover/long-press before opening.)

## 5. Degraded states & freshness

**Finding 5.1 — A stale board that looks fresh is worse than no board.** One failed MCP source and "synced 07:42" becomes a lie for that surface.

**Refinement:** per-source freshness chips (email 07:42 · slack 07:42 · jira **failed 06:00**) and a stale banner when any source exceeds 2× its cadence. Waiting-on math must exclude windows where the source was dark — "4 days silent" is false if Slack wasn't syncing for two of them.

**Finding 5.2 — Empty states are unspecified.** No Critical Now items is a *good* morning and should feel like one ("Nothing critical. 3 opportunities, 2 waiting."), not like a broken page.

## 6. Re-entry & rhythm (P4, P2)

**Finding 6.1 — The board shows state, not delta.** After 3 days out, the user needs the narrative: what resolved itself, what got decided, what's newly on fire. This is exactly the telescope pattern.

**Refinement:** when absence exceeds ~2 days, Operate opens with a collapsible *While you were away* brief — decisions made, threads concluded, new workstream proposals, agent activity — before the tiers.

**Finding 6.2 — No user review ritual.** The system has a weekly review (split/merge proposals) but MYN/GTD both hinge on the *user's* weekly sweep: Over the Horizon reconsidered, stale Waiting-On escalated or released, closure proposals adjudicated, holding-pen identities cleared.

**Refinement:** a scheduled *Review Friday* session (aligned with reporting cadence) that batches exactly those queues into one guided pass. Horizon items never badge during the week; they surface here.

## 7. Mobile & away-from-desk

**Finding 7.1 — Browser-primary means desktop-primary, but glances happen on the phone.** Full triage on mobile is neither needed nor wise; pretending otherwise complicates every interaction.

**Refinement:** define the phone experience as *glance + capture*: read the board (Critical Now and Waiting On first), open deep links, and capture a note/intent into the store inbox for desktop triage. All mutation-heavy flows remain desktop.

## 8. Attention economy (P1, P5)

**Finding 8.1 — Three badges can become three nags.** Badge fatigue kills command centers; the user stops believing the numbers.

**Refinement:** badge discipline as policy: badges count only items that genuinely need the user (unconfirmed + unread in actionable tiers); Horizon never badges; snoozed items are invisible until due; Reflect badges only on cadence-generated rollups; Know only on pending promotions. If a badge is ever wrong about "needs you," that's a bug.

**Finding 8.2 — Personal streams shouldn't inherit work urgency.** Ajilty at 9pm should not render alert-red anywhere.

**Refinement:** per-workstream profile (work | personal) tempering urgency styling and notification eligibility; personal streams get no Critical Now unless the user puts them there.

## 9. Scheduling honesty (P1)

**Finding 9.1 — Blocks have length; actions don't.** A 90-minute block absorbing six actions is silent overcommitment — the classic daily-plan failure.

**Refinement:** lightweight effort estimates on actions (S/M/L → minutes); blocks show fill level and warn on overflow. Estimates are AI-proposed, correctable, and another learning signal.

## 10. Measurability

**Finding 10.1 — Success metrics are named but not instrumented.** Missed-item rate, time-to-triage, and follow-up catch rate can all be derived from the event stream already specified — but only if the events are designed for it now.

**Refinement:** add session markers (triage_started/ended) and derive weekly instrumentation into Reflect: time-to-board-zero, items resolved per session, nudge→reply conversion, drift items closed. The system reports on itself with the same rollup machinery.

---

## Prioritized changes

**A. Adopt into the spec now**
1. Critical Now soft cap (≤5) with visible auto-demotion reasoning.
2. Provenance-on-claim: every compiled signal links to its source message.
3. External-origin discipline: sender-claimed urgency is marked and cannot alone reach Critical Now.
4. Actor-attributed events (`actor: user|agent`) + Agent activity audit view.
5. Per-source freshness chips, stale banner, and silence math that excludes dark windows.
6. Keyboard triage vocabulary + command palette (desktop).
7. *While you were away* re-entry brief (absence > 2 days) and *Review Friday* guided sweep.
8. Cold-start design: day-one value from dates + silence detection; workstreams as proposals; settling-in indicator; 10-minute seeding interview.
9. Phone = glance + capture; mutation-heavy flows desktop-only.
10. Story prose budgets (12/14/18 words) as compilation constraints.
11. Badge discipline policy and work|personal workstream profiles.
12. Block fill/overflow via S/M/L effort estimates.

**B. Add to delegated design work**
Story-compilation quality + eval harness (budgets, claim-linking, external-marking); demotion-ranking algorithm for tier overflow; effort-estimate learning; instrumentation event additions and self-metrics rollup; capture-inbox flow from phone.

**C. Parked**
Hash-chained ledger tamper evidence; multi-day planning horizon; capacity forecasting beyond per-block fill.
