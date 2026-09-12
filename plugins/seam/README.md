# Seam

Personal communications command-center **overlay** (n=1). Syncs email, chat,
and calendar through MCP into a per-profile file store, infers threads →
workstreams → working groups bottom-up, and compiles a static triage board.
Draft-in-place only — nothing in this plugin can send, post, or notify another
person.

Authority chain: `docs/seam-build-run.md` (executable authority) >
`docs/seam-design-spec.md` > `docs/seam-design-brief.md`. On conflict, stop and
flag. `docs/seam-design-review.md` holds rationale;
`docs/seam-fixture-walkthrough.md` traces the fixture scenarios;
`docs/PERSISTENCE.md` defines where changes persist (plugin vs. instance vs.
store) across machines and personas.

## Layout

```
bin/seam.mjs          CLI: init | sync | ledger
src/lib/              profile loader, store init + residency guard, ledger
src/adapters/         email / slack / calendar; fixture + live backends behind one contract
src/sync.mjs          watermark + fingerprint ingestion pipeline
src/board/            board template (M3) + jsdom smoke validator
fixtures/             MCP-shaped mock responses (walkthrough scenarios)
src/corpus/           synthetic UAT world (world.mjs) + deterministic generator
src/model/schema.mjs  data-model contract: enums + board-data validation
src/board/generate.mjs  store → schema-valid board-data (clustering, tiering)
src/board/render.mjs  board-data → static HTML (deterministic, escape-by-default)
src/compile/prompt.mjs  story compilation: fenced prompt + budget/marking linters
evals/run.mjs         the `make eval` gate: M0/M1 goldens + §6.1 banned-tools lint
profiles/*.template   persona profile templates — instances copy, never commit
skills/seam-sync/     /seam-sync skill for one sync pass
```

## Instance setup (per machine, per persona)

```
export SEAM_PROFILE=personal          # or work
node bin/seam.mjs init --profile personal   # copies template to ~/.seam/profiles/
# edit ~/.seam/profiles/personal.yaml: store_root, MCP bindings, principals
node bin/seam.mjs init                # creates the store at store_root
node bin/seam.mjs sync                # one pass; fixture backends until flipped live
node bin/seam.mjs board               # regenerate the static board from the store
node evals/run.mjs                    # the gate — must pass before live work
```

The work profile template ships disabled; enable only after work-side MCP
permissions are confirmed.

## Synthetic world (dev + UAT)

`node bin/seam.mjs corpus --out corpus-out --seed 42 --days 5 --per-day 300`
materializes a reproducible ~1,230-message week for a fictional security leader
across email/chat/calendar. It is the substrate for development and user-
acceptance testing in place of a real mailbox; ground truth in
`world-truth.json` lets inference be scored. See `src/corpus/README.md`.

## Status

- M0 (scaffold) and M1 fixture-mode (ingestion, idempotency, watermarks,
  dark-source isolation) pass `evals/run.mjs`.
- Live ingestion is fail-closed per surface until its shapes are captured and
  `docs/measurements.md` exists (Build & Run §4 M1).
- Board reference v7 is in hand: graduated to `src/board/template.html`, and
  `src/board/validate.mjs` passes 15/15 against it. The M3 work is the
  deterministic generator that renders this template from `board-data.json`.
- Headless sync scheduling (Build & Run §5): to be verified against current
  Claude Code docs during M0 wrap-up and recorded here.

## Dev dependency

The board smoke validator needs `jsdom`: `npm install --no-save jsdom`, then
`node src/board/validate.mjs`. It is not required for `evals/run.mjs`, which
runs the board validator only when jsdom is present.
