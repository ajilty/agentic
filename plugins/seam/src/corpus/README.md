# Seam synthetic world

A coherent, real-world-like communications surface for one fictional security
leader (Alex Cursi, `@stoneridge.example`) — the substrate Seam is developed,
demoed, and **user-acceptance-tested** against, in place of a real mailbox.

Two files are the durable asset; the corpus itself is regenerated on demand.

- `world.mjs` — **ground truth.** The person, ~11 recurring people (including a
  multi-affiliate identity collision), 7 workstreams with their surfaces /
  people / anchors / behavioural flavour, automation-noise sources, and the
  per-flavour lexicon. This is the source of truth; edit it to evolve the world.
- `generate.mjs` — a **deterministic** generator. Same seed → byte-identical
  corpus, so goldens are stable and the corpus never needs to live in git.

## Generate it

```
node bin/seam.mjs corpus --out corpus-out --days 5 --seed 42 --per-day 300
```

`corpus-out/` is gitignored. The **canonical acceptance corpus** is
`--seed 42 --days 5 --per-day 300` (~1,230 messages, ~246/day across email,
chat, calendar). Keep those params stable so UAT runs compare like-for-like.

Output layout (MCP-shaped — the exact shapes the live adapters normalize, so
the corpus exercises the real ingest path):

```
corpus-out/email/*.json      gmail-thread shaped
corpus-out/slack/*.json      channel-read shaped (threaded + unthreaded bursts)
corpus-out/calendar/*.json   event shaped (attendees corroborate working groups)
corpus-out/world-truth.json  ground truth for inference scoring
corpus-out/manifest.json     seed, params, counts
```

## What it deliberately exercises

- **Cross-surface through-lines** — the same workstream in email + chat + calendar.
- **Thread inference** — unthreaded channel bursts (Secure SDLC) and incident
  bursts (Phish Response) that clustering must reconstruct.
- **Delegation-and-silence** — the protagonist's own asks with no reply (the wedge).
- **External-urgency traps** — a vendor's "expires Friday", uncorroborated.
- **Automation noise** — bulk-headed CI/newsletter traffic for the FILTER path,
  including one poisoned body (injection-safety substrate).
- **Identity collisions** — `kai.rivera@` at two domains, different people.

## Why it stays past MVP

It is the UAT harness. Ground truth in `world-truth.json` lets inference be
*scored* (did clustering find these through-lines? did identity avoid the
name-only merge?), and the fixed seed makes every run reproducible. The eval
suite (`evals/run.mjs`) already gates on it: determinism, real-world volume,
volume ingest with no dark source, idempotency, and presence of the ground-truth
and FILTER/injection substrates.
