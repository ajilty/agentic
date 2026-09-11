# Contributing edges

The single source of truth for authoring `working-with-<tool>` knowledge
skills. The `/harvest` skill follows this file at contribution time; human
contributors follow the same rules. If guidance here conflicts with anything
else, fix this file.

## What an edge is (and is not)

An edge is a sharp piece of operating knowledge that documentation does not
carry: a gotcha, a failure mode, a misleading flag, a response shape that
surprises, a workaround with the exact working incantation. Docs lookup is
already served (context7, vendor plugins) — if a docs query answers it, it is
not an edge. The best edge starts from a raw observation: the verbatim error
string, the command that failed, the variant that worked.

Each edge entry is symptom, cause, and what works, in a few terse lines.
Quote error strings verbatim (minus identifiers). Prefer the runnable
incantation over a description of it.

## Shape and size

- One skill per tool surface, named `working-with-<tool>` (kebab-case), one
  `SKILL.md`, nothing else. **A section beats a new skill**: a new skill adds a
  description every session pays for on every turn, while a section in a body
  costs nothing until the skill fires. Split only when the triggers genuinely
  differ, never to make a long skill look shorter.
- Body is terse bullets grouped by operation area (auth, search, writes, ...).
  A new skill can start with 2-3 edges; a single contribution to an existing
  skill is often one bullet, or a measurement folded into an existing one.
- **The description is the API, and it is the part every session pays for.**
  Skill descriptions load into context on every turn whether or not the skill
  fires, and the harness silently truncates the listing at 1,536 characters
  (documented in the Claude Code skills reference). The description has one
  job: fire whenever the model is about to touch the tool surface. It follows
  this template, and `tests/test_descriptions.sh` enforces the cap:

  > `<Vendor> <surface> (<tool family or the main tool names>). Load before the
  > first <X> call in a session[ and before writing <query language>]; covers
  > <three to five operation areas>. Also when <user-utterance cues>.`

  Budget **400 characters, hard cap**. Three things are allowed in: the tool
  surface (so the model matches it against the tools it is about to call), the
  load-before-first-call sentence, and cues that arrive in the *user's* words
  before any call ("is X still installed", "did anyone answer this"). Nothing
  that only appears *after* a call belongs there: no error strings, field
  names, response shapes, or measurements. Those are body content; if the
  skill fired on the first call they are already loaded, and if it did not, a
  list of error strings is the weakest match path there is. The reference
  case is `working-with-crowdstrike-mcp`.
- **The body is budgeted by review, not by count.** A body loads only when the
  skill fires, so a long skill is not wrong if every bullet earns its lines.
  The test is *minimum viable edge*: the shortest text that keeps the
  incantation, the verbatim string, and any correction. The
  `edges:harvest-review` subagent applies it to every contribution and may
  return `compress` with a shorter proposal. Two smells it looks for: framing
  repeated across bullets ("silently, with no error") and a new bullet where a
  measurement in an existing one would do. There is no line cap; a skill that
  keeps growing gets a `diet` pass (`/edges:harvest diet <tool>`) instead. A
  diet compresses, and may also **prune** bullets that fail the edge test
  (documented behavior, tradecraft without a failure behind it); every prune
  is listed in the PR body and a human confirms the list before merge. The
  author proves nothing operational was lost by diffing the set of
  backtick-quoted tokens and every number between old and new.
- Every skill ends with the report-link footer:

  ```
  ---
  Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
  ```

## Redaction (public repo, publishable tier)

Zero user, company, tenant, or person references, and no dated incident
anchors. Account IDs, hostnames, internal URLs, and case numbers are replaced
with placeholders; error strings stay otherwise verbatim. If an edge cannot be
written without naming an org or person, it belongs in private harness config,
not here.

Activate the leak guard in your clone before committing (identity allowlist +
private blocklist scan):

```sh
git config core.hooksPath scripts/githooks
```

## Where to edit

Edit `skills/knowledge/<skill>/` at the repo root — the library. The plugin's
`plugins/edges/skills/` entries are directory symlinks (views); `rg`/`grep -r`
do not follow them, and edits belong in the library. A new skill needs both
the library directory and the symlink:

```sh
ln -s ../../../skills/knowledge/working-with-<tool> plugins/edges/skills/working-with-<tool>
```

Add the new skill's row to the table in `plugins/edges/README.md` and bump the
plugin version in `plugins/edges/.claude-plugin/plugin.json`.

## Validate and submit

- `claude plugin validate plugins/edges --strict` must pass (CI runs it on
  every PR via `scripts/validate-plugins.sh`, ADR-0038).
- Commit with an `edges(<tool>): <edge>` subject (see `git log --oneline --
  skills/knowledge` for the style), branch, push, and open a PR. CI's review
  runs when the PR goes ready-for-review.
- No push rights, or the observation is not yet edge-shaped? File it instead:
  https://github.com/ajilty/agentic/issues/new?template=edge-report.yml — the
  raw redacted observation is a welcome contribution on its own.
