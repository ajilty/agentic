---
name: harvest-author
description: Author an edges-library contribution in isolation from confirmed candidates. Clones the repo, checks for colliding open PRs, edits the library, validates, opens a draft PR. Invoked by the harvest skill, not by users.
user-invocable: false
context: fork
agent: general-purpose
argument-hint: "candidates | revise <branch> + verdict | ship <branch> | diet <skill>"
---

# Harvest author

You are writing to the edges library of `ajilty/agentic` from candidates
someone else confirmed. You have no view of the session they came from; the
argument is everything you know. Work in scratch space, never in a checkout
the user may be sitting in.

## Setup, every mode

1. Clone `https://github.com/ajilty/agentic` into a fresh scratch directory
   and `git config core.hooksPath scripts/githooks` (leak guard).
2. Read `plugins/edges/CONTRIBUTING.md` and follow it; it is the authority on
   edge shape, budgets, redaction, wiring, and commit style.
3. **Collision check.** `gh pr list --state open --json number,headRefName,files`
   and note every open PR touching the target skill. If one exists, branch
   from its head instead of `main` and say so in the PR body; two PRs editing
   the same skill against the same base is the failure this step prevents.

## Mode: candidates (default)

For each candidate, read the whole target skill before adding a line:

- If an existing bullet already covers it, strengthen that bullet (a
  measurement, the verbatim string) rather than adding a sibling.
- If it is a generic connector pattern, write it in
  `working-with-mcp-connectors` and leave at most a one-line pointer in the
  vendor skill.
- Otherwise add the edge where its operation area lives: symptom, cause, what
  works, verbatim error string, runnable incantation. Terse.
- Correcting a live claim: rewrite in place and say "this corrects" in the
  bullet; never leave the old and new side by side.
- Description: add only the trigger strings a model would actually see
  (error text, tool or parameter names). No summaries of the body.

Then `bash scripts/validate-plugins.sh`, commit with an
`edges(<tool>): <edge>` subject, push, and open the PR **as a draft**
(`gh pr create --draft`) with a body listing each edge and its redaction
statement. Return: branch name, PR URL, and per edge one line on where it
landed and why there.

## Mode: revise <branch> + verdict

Check out the branch, apply the verdict literally: use the reviewer's
`compress` text, drop `redundant` and `not-an-edge` items (say so in the
commit), and if a drop empties the PR, close it and return that. Re-validate,
push, return a one-paragraph summary.

## Mode: ship <branch>

`gh pr ready <number>` so CI's review fires (it only runs on the draft-to-ready
transition). Return the PR URL.

## Mode: diet <skill>

No new content. Read the skill and rewrite it to its minimum viable form
without losing an incantation, a verbatim error string, or a correction:
merge bullets that share a cause, cut repeated framing ("silently, with no
error" once per section, not per bullet), and reduce the description to
triggers. Open as a draft PR titled `edges(<tool>): diet` whose body lists
what was merged and confirms nothing operational was dropped. Return as in
candidates mode.
