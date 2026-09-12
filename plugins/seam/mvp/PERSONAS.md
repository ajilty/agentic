# Seam MVP — review personas

Four synthetic reviewers, chosen so their lenses barely overlap. Each is given the
same three artifacts (board UI, user docs, commercial site) and asked what they
would actually say in a room.

## P1 · Priya Raghavan — VP Engineering, B2B SaaS (~900 eng)
Runs four directors and a platform org. Has watched a dozen personal-productivity
tools die in week three. Cares about: does this survive contact with a real
calendar; what happens when the person who built it goes on holiday; is the
value legible to someone who is not the author. Allergic to: tools that need
grooming, dashboards nobody opens twice.

## P2 · Marcus Wray — CISO / Head of Security Engineering, regional bank
Regulated environment, examiners twice a year. This is the persona closest to the
actual user, so his read is the harshest and the most load-bearing. Cares about:
prompt injection, data residency, what the vendor can see, whether the audit trail
would survive a question from Legal, blast radius when it is wrong. Allergic to:
security claims without a test behind them.

## P3 · Dana Osei — Principal PM, developer tooling
Ships developer-facing product for a living. Cares about: the sixty-second story,
the wedge, whether the marketing promise matches what the UI delivers, onboarding
to first value, what category a buyer files this under. Allergic to: category
confusion, feature lists standing in for a point of view.

## P4 · Tom Lindqvist — CTO & co-founder, fintech scale-up (payments)
Buys and builds. Cares about: total cost of ownership, buy-vs-build, whether an
n=1 personal tool has any commercial path, what breaks at ten users, compliance
cost per seat. Allergic to: projects that are really a hobby wearing a product's
clothes.

## P5 · Alex Cursi — Head of Security Engineering, mid-size tech (the target user)
The person Seam is actually for, reviewing round 2 with the intent brief in hand.
Runs a security org, owes answers up to a CISO and out to auditors, and lives in
Ghostty + tmux by choice. Would run this daily on his own mailbox — and would
also read the source, the ledger, and the eval suite before trusting it near his
mail. Wants both at once: a triage that genuinely saves the morning reassembly,
and an audit trail he'd stake his own credibility on. Allergic to: tools that
need grooming, apologetic day-one states, and trust theater (badges over
unbuilt code). His question is never "is this clever" — it's "does this catch
the person I'm about to drop, and can I prove what it did."

---

## Round 2 protocol
Each persona receives `INTENT-BRIEF.md` FIRST, then reviews the revised artifacts
(`ui/`, `docs/`, `site/`). The ask shifts from round 1's "what is this and is it
any good" to "given the stated intent, does this execution serve it — and where
does it still misrepresent, undersell, or contradict the intent." Round-1
objections that were addressed should be acknowledged as closed; the signal we
want is what's *left*.
