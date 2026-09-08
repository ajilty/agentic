---
name: intel-to-impact
description: Run any incoming security signal from intake to a held disposition and a reportable funnel entry. Use when a security signal arrives — external intel (advisory, CVE, IOC set, vendor pentest finding) or internal (detection, anomaly, user report, inbound ask) — or to backfill funnel fields on a disposition reached another way. Defines the step-to-step interfaces; deep investigation stays in the environment's own investigation processes.
---

# Intel to Impact

A standards-informed workflow (NIST 800-61 lifecycle; MITRE ATT&CK as the join key
across intel, detections, and coverage; kill-chain position as the depth gauge) run
over the environment's existing investigation processes. This skill owns the pipeline
and the **interfaces between steps** — what each step consumes and what it must hand
forward. Deep procedure lives in the routed processes; never restate or override them.

Steps run inline for one signal; for several, S4 runs as one read-only subagent per
signal in parallel. The interface is the contract either way — a step's output is
complete when every field below is present or explicitly n/a.

```
S1 Intake → S2 Ground → S3 Route → S4 Investigate → S5 Corroborate
                                                        → S6 Disposition (HELD)
                                                        → S7 Act (gated)
                                                        → S8 Report & carry
```

## Interface: Signal (created S1, enriched by every later step)

- **id** — native identifier(s) verbatim (composite id, issue UUID, message id),
  captured at first sight; **link** — the source's own deep-link field, never a
  constructed URL; `n/a` where the source exposes none (PhishER rows, pasted
  advisories) — the native id carries identity
- **class** — `intel-advisory` | `vulnerability` | `detection` | `reported-email` |
  `pentest-results` | `unclassified`
- **observed / received** timestamps; **summary** — one line, who/what/where

## S1 — Intake

**In:** raw arrivals (sweep output, console pull, inbox item, pasted advisory).
**Do:** capture every item as a Signal. No judgment, no filtering — the funnel counts
what arrives, not what survives.
**Out:** Signal list.
**Exit:** every arrival has a Signal with its native id, and a link or `n/a`.

## S2 — Ground

**In:** Signal list, carried items, and whatever local knowledge marks simulations
and sanctioned activity (phishing-simulation infrastructure, authorized pentests).
**Do:** dedupe — same story seen across detections or planes collapses to one Signal
keeping all native ids; strip simulations and sanctioned activity; match known
carried classes.
**Out:** each Signal gains **ground**: `new` | `duplicate-of <id>` | `simulation` |
`authorized` | `carried-class <name>`. Stripped and carried-class Signals skip to S8
(verdict `benign` for simulation/authorized; `pending-carried` for a class match not
individually verified).
**Exit:** no two Signals tell the same story.

## S3 — Route

**In:** grounded Signals.
**Do:** assign each class to the local process that owns it, and phrase the
**investigation question** — the single question S4 must answer for this Signal.
Resolve owners locally: prefer the environment's own skills/processes for each class
(discover by name and description); where none exists, run the qualify gates inline
and nominate a candidate process in the record.

| class | owning process (resolve to the local equivalent) |
|---|---|
| intel-advisory | IOC / threat hunt across the estate |
| vulnerability | exploitability-here assessment (presence ∧ exposure ∧ exploitability) |
| detection | read-only telemetry investigation to a defensible verdict |
| reported-email | email legitimacy / phishing analysis |
| pentest-results | pentest digest to a decision-ready verdict |
| unclassified | inline qualify gates; nominate a candidate process |

Two classes matching at once — an advisory naming a CVE is both — is decided by
**the question the signal poses, not its packaging**: indicators to hunt across the
estate is `intel-advisory`, a named defect to assess for exploitability here is
`vulnerability`.

**Out:** **route** + **question** on each Signal.
**Exit:** every surviving Signal has both.

## S4 — Investigate (read-only; parallelizable per Signal)

**In:** one Signal + its question. The routed process's own procedure governs; this
step defines only what must come back.
**Out — Interface: Finding**
- **answer** to the question
- **claims[]** — each labeled `CONFIRMED` (query/field/record cited) or `INFERRED`
  (basis named)
- **gates** — presence / exposure / exploitability-or-intent, each `yes` | `no` |
  `n/a` with basis. Rank by known-exploited (KEV) status plus exploitability ×
  reachability × blast radius — never CVSS-base alone, never presence counts
- **blind-spots[]** — what this telemetry plane cannot see
- **techniques[]** — ATT&CK IDs exactly as supplied by sources; never derived —
  `n/a` when the source's own tags are not ATT&CK IDs (PhishER labels, vendor
  severities)

**Exit:** the question is answered, or declared unanswerable with the missing
telemetry named.

### Enrichment (S4/S5, directional — discover, don't assume)

Before declaring an indicator uncharacterized, check what enrichment the environment
actually offers and use the best of it: threat-intel or reputation MCPs/connectors,
OSINT lookups (web search, WHOIS/ASN, passive DNS), hash and sandbox services, and
any CLI tools on PATH. This is deliberately not a list — inventory what exists at run
time and prefer purpose-built over generic (a threat-intel connector over raw web
search) when both are present. Two rules: external reputation is its own
corroboration plane, labeled like any other (INFERRED unless the provider's evidence
is cited); and enrichment never substitutes for internal telemetry — it explains a
signal, it cannot clear one.

## S5 — Corroborate

**In:** Finding.
**Do:** test the leading explanation on a **second independent telemetry plane**;
resolve any cross-signal link to `CONNECTED` | `REFUTED` | `INSUFFICIENT-DATA`
(shared egress IP or tenant is co-location, not linkage).
**Out:** Finding extended with **corroboration[]** and any revised claims.
**Exit:** no verdict rests on one plane; every claimed link is labeled.

## S6 — Disposition (always HELD)

**In:** corroborated Finding.
**Out — Interface: Verdict**
- **verdict** — `benign` | `benign-with-actions` | `needs-response` |
  `insufficient-data` | `pending-carried`. `benign-with-actions` is the single
  bucket for no compromise but action needed: nothing was compromised on the
  evidence available, yet the disposition carries an action that must happen anyway
  — a structural control gap, an authorization still to confirm, a plane too dark
  to clear this class again. Fleet-wide remediation instead means `needs-response`;
  an unanswered question means `insufficient-data`
- **confidence** — high | moderate | low, plus the one observation that would change it
- **stage-reached** — `delivered` | `blocked-at-gateway` | `blocked-at-execution` |
  `executed` | `persisted` | `exfiltrated` | `authorized-actor` | `n/a`.
  `authorized-actor` records insider and authorized-actor activity, which has no
  kill-chain position: say what the principal did and whether it stayed inside the
  grant, in the claims, instead of forcing a stage onto it. `n/a` stays for signals
  with no actor activity to place
- **residuals[]** — named, each with why it stays unresolved
- **class-finding** — the process gap this instance exposes, if any (the funnel's
  real product; most verdicts are benign, the gap is what compounds)
- **recommended-actions[]** — each tagged `tier-1` (read-only, safe to auto-run) |
  `tier-2` (draft-and-hold) | `tier-3` (operator-only: approvals, risk acceptance,
  spend)

**Exit:** HELD. Nothing executes from this step; show-before-send is not waived by
any mode.

## S7 — Act (gated)

**In:** Verdict + an explicit operator instruction naming the action.
**Do:** only the named action. Console writes batched with resolution tags and a
comment naming the human; anything outbound drafted and shown first.
**Out:** action-log lines appended to the Verdict (what, when, under which identity).
**Exit:** every executed action traces to an instruction.

Handoff: a `needs-response` vulnerability verdict requiring fleet-wide remediation
hands off to the `respond-to-vuln` playbook (explicit-invoke, same plugin) for its
closure phases — define "fixed", baseline, watch, close — entering at its phase 4
when the assessment already did the scoping. Remediation the operator coordinates
out-of-band (a user action, an IT ticket) is still logged here as an action line.

## S8 — Report & carry

**In:** all Verdicts and intake-only Signals.
**Do:** one **funnel entry** per Signal — class, verdict, stage-reached,
techniques, each `n/a` where the source cannot supply it —
recorded wherever the session's output lives; a **funnel strip** wherever the
environment publishes its standing security report (else the session record):
signals in → deduped → investigated → verdict mix → stage mix → writes. Every
Signal counts in exactly one verdict bucket — `benign-with-actions` is its own,
never a split across `benign` and `needs-response`. Carry
`pending-carried` and `insufficient-data` items with native ids and the exact query
that will verify them (verify on first carry, not day six). For an active condition
dispositioned benign but still generating signal, a short read-only verification
watch (re-query the named signal past ingest lag; two clean intervals = closed)
confirms closure instead of assuming it. Promote class-findings to the report's
decision items.
**Exit:** close the loop through the environment's session-record / retro mechanism
if one exists, so lessons feed later codification.

## Backfill mode

For a disposition already reached another way — a completed investigation, a triage
close, a vendor's answer — that the operator asks to land in the funnel.

**In:** the operator's pointer to that record, and nothing else.
**Do:** skip S1–S5 — no new queries, nothing reconstructed from memory. Read the
Signal fields (native id, link, class, timestamps, summary) and the Finding's answer
off the record, run S6 over that evidence alone, then S8.
**Out:** one funnel entry tagged `backfilled` — so the strip's *investigated* count
never claims work this run did not do — plus any class-finding, promoted as usual.
**Exit:** every field is cited to the record or `n/a` with the reason; a record that
cannot carry a Verdict enters the pipeline at S3 as a normal Signal instead.

## Standards map

| Steps | NIST 800-61 phase | Framework use |
|---|---|---|
| S1–S2 | Detection & Analysis (validation) | dedupe, simulation-strip |
| S3–S5 | Analysis | ATT&CK joins intel ↔ detections ↔ coverage; kill chain positions the event |
| S6 | Analysis → containment decision | stage-reached is the kill-chain depth gauge (`authorized-actor` where no kill chain applies) |
| S7 | Containment / Eradication | gated, single-writer |
| S8 | Post-incident activity | lessons feed codification |

## Escalation triggers (do not act preemptively)

- Fields landing inconsistently across ~2 weeks of records → harden routing/fields.
- S4 outputs repeatedly missing Finding fields → turn the Finding interface into a
  fill-in checklist handed to the subagent.
- A coverage question the machine-supplied technique tags can't answer → tag
  techniques on every disposition.
- A verdict mapping to two buckets or none → revisit the vocabulary (this trigger
  produced `benign-with-actions`; a case that still splits is a fresh gap to
  record, not a judgment call to make on the spot).
