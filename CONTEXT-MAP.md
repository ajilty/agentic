# Context map

This repo holds more than one bounded context. Each keeps its own `CONTEXT.md`
glossary; repo-wide decisions live in [docs/adr/](docs/adr/INDEX.md).

| Context | Glossary | Language of |
|---------|----------|-------------|
| orchestrate | [plugins/orchestrate/CONTEXT.md](plugins/orchestrate/CONTEXT.md) | the standing operator loop: Router, personas, lanes, oracles |
| shipyard | `plugins/shipyard/CONTEXT.md` (lands with the plugin; design in [docs/specs/2026-08-07-shipyard-plugin-design.md](docs/specs/2026-08-07-shipyard-plugin-design.md)) | the four-segment delivery method: segments, pauses, memos, decision logs |

Term collisions across contexts are legal; translate at the boundary:

- **spec**: in shipyard, the third segment and the requirements/build documents
  it produces; in orchestrate, the Planner's signed per-goal artifact.
- **operator** (orchestrate) and **the human** (shipyard) name the same person:
  the one driving.
