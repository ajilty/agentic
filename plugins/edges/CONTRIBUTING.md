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
  keeps growing gets a `diet` pass instead. A diet compresses, and may also
  **prune** bullets that fail the edge test (documented behavior, tradecraft
  without a failure behind it); every prune is listed in the PR body and a
  human confirms the list before merge. The author proves nothing operational
  was lost by diffing the set of backtick-quoted tokens and every number
  between old and new. Nobody schedules a diet: the author runs one in the
  same branch whenever a skill it is touching is over 16 KiB or the prompt
  audit flags it, and `tests/test_descriptions.sh` prints a `NOTE` for any
  body over 16 KiB so the size is visible on every PR. `/edges:harvest diet
  <tool> [: direction]` still runs one by hand.
- **Every touched skill is audited.** The author runs the bundled prompt
  audit on each skill directory it changes (`/claude-api prompt-audit
  skills/knowledge/<skill>`, path required) and folds high- and
  medium-confidence findings into the same PR. The audit finds process debt
  rather than model drift here: relative phrasing about the file's own past,
  harness mechanics the model already has, a rule stated twice. So a bullet
  never refers to its own history. A correction states the current fact (and,
  where the wrong claim is widely repeated, the negative with its evidence);
  "corrects" goes in the commit message.
- **A repeat hit is a measurement.** A harvested failure that an existing
  bullet already covers is not dropped as redundant: it says the edge did not
  work. If the skill had not loaded in that session, the description missed
  the surface; if it had, the bullet did not prevent the failure. Harvest
  records which, and the fix is to the description or the bullet. Every
  harvest ends with a per-skill scorecard (`new / repeat / correction`
  counts) that the PR body carries; a skill whose repeats plus corrections
  match or exceed its new edges gets a verdict line and is rewritten rather
  than appended to. Volume is not the signal, the mix is.
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

Add the new skill's row to the table in `plugins/edges/README.md`.

**Bump the plugin version in `plugins/edges/.claude-plugin/plugin.json` on every
merged change, body-only edits included** (patch for edges, minor for a new skill).
Installs cache the plugin by version, so a merge that leaves the version alone never
reaches anyone's sessions: `/plugin update` reports "already at the latest version"
while the skills on disk stay stale.

## Validate and submit

- `scripts/check.sh` must pass: it runs what CI runs, including
  `claude plugin validate --strict` on every plugin (ADR-0038). A failure that
  also reproduces on main is not pre-existing unless main's latest CI run is red
  on the same check (`gh run list --branch main --workflow tests`).
- Commit with an `edges(<tool>): <edge>` subject (see `git log --oneline --
  skills/knowledge` for the style), branch, push, and open a PR. CI's review
  runs when the PR goes ready-for-review.
- No push rights, or the observation is not yet edge-shaped? File it instead:
  https://github.com/ajilty/agentic/issues/new?template=edge-report.yml — the
  raw redacted observation is a welcome contribution on its own.
