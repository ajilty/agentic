---
name: harvest
description: Harvest this session's tool-call learnings into the edges library. Extracts candidates here, confirms them with you, then hands authoring and review to forked subagents so this session keeps its context.
disable-model-invocation: true
argument-hint: "[tool] [: observation or direction, e.g. 'new skill' / 'fold into existing'] | diet <tool>"
---

# Harvest

Turn what this session learned the hard way into a contribution to the edges
library (the `working-with-<tool>` skills of the `edges` plugin, repo
`ajilty/agentic`). This skill does the cheap part in-session and delegates the
rest, so the session that did the real work is not spent on paperwork.

## 1. Extract (here, briefly)

Scan this session's tool calls for edge candidates: verbatim error strings that
forced a workaround, retry-until-worked sequences, misleading flags or
parameters, response shapes that surprised, a filter that returned empty while
the data was there. Sharp edges only: anything a docs lookup answers is not a
candidate.

With no arguments, sweep the whole session. An argument names the tool to
focus on; prose after it is the observation itself or direction ("new skill",
"fold into the existing one"), and the user's direction binds. `diet <tool>`
skips extraction and sends the named skill straight to the author for a
compression pass (step 4, diet mode).

Redact as you collect: no user, company, tenant, or dated incident specifics;
keep error strings otherwise verbatim.

**Also read the failure journal.** The plugin's hooks append every tool
failure to
`${EDGES_JOURNAL:-${XDG_STATE_HOME:-$HOME/.local/state}/edges/journal.jsonl}`.
The journal is a raw local store: rows are scrubbed of emails, URLs, IPv4,
UUIDs, digit runs, and home paths at capture, but nothing more — they still
carry names, orgs, tickets, and products. The "Redact as you collect" rule
above is what actually keeps identities out of a contribution; apply it to
journal rows the same as to anything else you pull from this session, since
you are the harvester and identity redaction happens here, before anything
leaves the machine.
Rows newer than the timestamp in the sibling `journal.cursor` file are
unharvested; group them by `tool` and `fp`, so a failure that hit five times
shows as one candidate with a count. Each row carries `transcript_path` and
`tool_use_id`: when a candidate needs the retries and the variant that worked,
`grep` the id in that transcript rather than asking the user to remember. The
journal captures what errored; the silent incomplete answers that make up
most edges still come from your own read of this session. Journal rows are
local-only and their `tool` field carries the user's MCP server alias
(`mcp__<alias>__<tool>`); an alias may name an entity, so normalize it to the
vendor (`mcp__wiz__...`) before anything reaches a candidate.

## 2. Confirm

Present the candidates in one message: for each, the observation (one or two
lines), the likely target skill, and whether it reads as vendor-specific or as
a generic connector pattern (those belong in `working-with-mcp-connectors`,
with at most a one-line pointer in the vendor skill). Ask which to submit.
Nothing is written before the answer, except the cursor: once the candidates
are on screen, write the current UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)
to `journal.cursor` so dismissed rows do not resurface next session.

## 3. Hand off

Invoke `edges:harvest-author` with the confirmed candidates as its argument:
one block per candidate carrying observation, target skill, and any user
direction. For a diet, skip steps 1 and 2 and invoke it with `diet <skill>`.
Do not clone, edit, or open PRs from this session.

Both forked skills run in the **background**: the invocation returns at once
and the result arrives later as a task notification. Give the user a
three-line status and stop; continue the chain from the notification, not by
waiting. Every mode of the author returns the branch name, the PR URL, and a
per-edge (or per-prune) line naming the file it landed in; the reviewer
returns a verdict.

## 4. Review, then ship

When the author's notification arrives, fan the review out. The author stays
single because its cross-file view catches duplicates and misfiled edges;
review splits because a reviewer reading one file judges it more closely than
one reading the whole branch. In one turn, invoke `edges:harvest-review`
once per skill file the branch changes, all in parallel, each with
`<branch> <skill-path> round 1` followed by the confirmed observations for
the edges the author says landed in that file. Alongside them, invoke it once
more with `branch <branch> round 1` for the branch-level checks (cross-file
duplicates, misfiling, identity leaks across the whole diff, commit body,
version bump, description caps). Each returns a verdict per edge in its file:
`accept`, `compress` (with the shorter text), `redundant` (with what already
covers it), or `not-an-edge`; the branch instance returns findings, each
naming a file or the `branch` bucket (commit message, PR body, identity
leaks outside skill files, `plugin.json`, description caps). Act once every
notification is in. Save each verdict to a file in scratch, one per scope and
round, since each reviewer is a fresh fork and the next round needs it.

A diet does not fan out: it touches one skill, so invoke the reviewer once
with `diet <branch>`. It returns a verdict per prune plus its own check that
nothing operational was lost.

- All `accept`, every file and the branch instance: invoke
  `edges:harvest-author` once more with `ship <branch>` so it marks the draft
  PR ready for review. **Except a diet:** a diet PR stays draft, and you hand
  the user its URL with the prune list so they confirm the removals before
  marking it ready themselves.
- Anything else: invoke `edges:harvest-author` with `revise <branch>` and
  only the non-`accept` verdicts, each under its file, with each branch
  finding filed under the file it names or under `branch`, which routes to
  the author like any file. Then re-review only those scopes, plus `branch
  <branch>` again (a revise rewrites the commit, and a drop can empty a
  file), passing each reviewer `round <n> prior <verdict-path>` with that
  scope's saved verdict from the round before: `<branch> <skill-path> round
  <n> prior <verdict-path> + observations`, `branch <branch> round <n> prior
  <verdict-path>`. A file that came back all `accept` with no branch finding
  is not reviewed again. Two rounds is the budget, counted per scope, and
  `branch` is a scope with its own counter. A scope still objecting on its
  third review goes to the user instead of looping; nothing ships until every
  scope accepts or the user settles it.

Relay to the user only the PR link and what changed, in one paragraph.
