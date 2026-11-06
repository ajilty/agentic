---
description: "Record run feedback durably: full qualitative review to eval/reviews/ + a version-stamped rating row in feedback.jsonl (Tier 3c feedback loop)."
---

# Orchestrate feedback

Capture operator feedback on the current orchestrate run **durably**: feedback that only
lives in chat is lost to the plugin's improvement loop (ADR-0028). Two artifacts, both
under `.agents/runs/orchestrate/eval/` in the repo root:

1. **The full qualitative review** → write it to `eval/reviews/<UTC-ts>.md`. Shape it the
   way reviews are actionable (each point tied to a SPECIFIC dispatch/lane with evidence,
   never vibes):
   - **Rating:** one line (e.g. "strong: 4 lanes shipped, verifier caught real defects").
   - **What worked:** each item names the lane/dispatch and the concrete catch or win.
   - **What to improve:** each item names the dispatch, the defect/friction, and the
     evidence; say which existing rule it violates (batch-by-tier, the clarify step,
     ADR-00xx) or whether it is a NEW gap.
   - **Open at feedback time:** anything in flight the next session must know.
   Fold in whatever the operator said verbatim; their phrasing is signal.

2. **The durable row** → from the repo root run:
   `ledger.sh feedback "$ARGUMENTS review:eval/reviews/<UTC-ts>.md"`
   (bare `ledger.sh` resolves via the plugin bin shims, ADR-0018). This appends a
   version-stamped record embedding the metrics snapshot (shipped, friction,
   verify_coverage, model_mix) alongside the note + review pointer.

Then give the operator the two-line read: **shipped** changes and **healthy** escalations
(forks/decisions: the tool correctly surfacing hard calls) versus **friction** (rejects,
oracle-inconsistencies, denials: the number to drive down).

**If you cannot execute shell here** (no Bash in this context): still produce the review
text in chat, and print the exact command for the operator to run themselves:
`! ledger.sh feedback "<rating> review:eval/reviews/<ts>.md"`, and ask them to paste the
review into that file. Never let the review evaporate in chat.
