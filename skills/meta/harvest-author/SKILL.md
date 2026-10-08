---
name: harvest-author
description: Author an edges-library contribution in isolation from confirmed candidates. Clones the repo, checks for colliding open PRs, edits the library, validates, opens a draft PR. Invoked by the harvest skill, not by users.
user-invocable: false
context: fork
agent: general-purpose
argument-hint: "candidates | revise <branch> + verdict | ship <branch> | diet <skill> [: direction]"
---

# Harvest author

You are writing to the edges library of `ajilty/agentic` from candidates
someone else confirmed. You have no view of the session they came from; the
argument is everything you know. Work in scratch space, never in a checkout
the user may be sitting in.

## Setup (candidates, revise, diet)

1. Clone `https://github.com/ajilty/agentic` into a fresh scratch directory.
   Before the first commit, do the repo's contributing setup (README
   "Contributing setup", pointed to from `AGENTS.md`): `git config
   core.hooksPath scripts/githooks`, and set the contributor's configured
   commit identity plus `hooks.expectedIdentity`. A fresh clone has neither,
   so without this the identity and leak guard never runs; one harvest commit
   already reached the public remote authored with the operator's work email
   that way. For `revise` and `diet` on an existing branch, check that branch
   out.
2. Read `plugins/edges/CONTRIBUTING.md` and follow it; it is the authority on
   edge shape, budgets, redaction, wiring, and commit style.
3. **Collision check (candidates and diet only).**
   `gh pr list --state open --json number,headRefName,files` and note every
   open PR touching the target skill. If one exists, branch from its head
   instead of `main` and say so in the PR body; two PRs editing the same skill
   against the same base is the failure this step prevents.

`ship` needs none of this; see below.

Every mode returns the same shape: branch name, PR URL, and one line per edge
(or per prune) naming the skill file it landed in and why. The harvest skill
reviews each file separately, so that file path is how review finds its edges.

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
- A candidate with decay `model` ends its bullet with
  `<!-- decays: model -->` (CONTRIBUTING, decay tag). Folding it into an
  untagged bullet keeps that bullet untagged: the tool half outlives the
  model half.
- Description: touch it only if the tool surface changed (a new tool family
  or a new user-utterance cue). It follows the CONTRIBUTING template: surface,
  "Load before the first call", operation areas, user cues; 400 characters
  hard cap. Error strings, field names and response shapes never go in it.

Then `bash scripts/check.sh` (the full CI mirror; `pre-push` runs it too).
A failure that also reproduces on main is pre-existing only if main's latest
CI run (`gh run list --branch main --workflow tests`) is red on the same
check; otherwise it blocks the PR and is reported, never shipped past.
Commit with an
`edges(<tool>): <edge>` subject, push, and open the PR **as a draft**
(`gh pr create --draft`) with a body listing each edge and its redaction
statement. If the skill's `SKILL.md` is now over 16 KiB, say so in the PR
body as a diet suggestion. Return the standard shape.

## Mode: revise <branch> + verdict

Check out the branch, apply the verdict literally: use the reviewer's
`compress` text, drop `redundant` and `not-an-edge` items (say so in the
commit), and if a drop empties the PR, close it and return that. The verdict
is grouped by file; edit only the files it names, since the others are
already accepted and will not be reviewed again. Findings under `branch` may
edit the commit message (amend), the PR body, and
`plugins/edges/.claude-plugin/plugin.json`. Re-run `bash scripts/check.sh`
(same rule as above), push, return
the standard shape.

## Mode: ship <branch>

No clone. `gh pr ready "$(gh pr view <branch> --json number -q .number)"` so
CI's review fires (it only runs on the draft-to-ready transition). Return the
PR URL.

## Mode: diet <skill>

No new content. Read the skill and rewrite it to its minimum viable form:
merge bullets that share a cause, cut repeated framing ("silently, with no
error" once per section, not per bullet), and rewrite the description to
the CONTRIBUTING template (surface, load-before-first-call, areas, user cues;
400 characters hard cap), moving any error string or field name it carried
into the body if the body lacks it. A diet may also **prune**
a bullet that fails the edge test: documented behavior, or tradecraft with no
failure behind it. A bullet tagged `<!-- decays: model -->` may also be
pruned when the argument carries evidence that the current model gets it
right unaided; the prune line cites that evidence, and a tagged bullet with
none stays. Direction after the skill name (for example "re-check
model-tagged edges") narrows the pass and binds. Never prune an incantation,
a verbatim error string, or a correction of a live claim on any other
ground; a "this corrects" note may go only when the claim it corrected is
gone too. Merging keeps a tag only when every merged bullet carried it.

Before committing, prove it mechanically: extract the set of backtick-quoted
tokens and every number from the old and new files and diff them. Anything
missing is either restored or named in the prune list; there is no third
option.

Open as a draft PR titled `edges(<tool>): diet` whose body has two lists:
what was merged, and what was pruned with one line of reason each. The prune
list is for a human to confirm before merge, so a diet PR is never marked
ready by `ship`; return the standard shape with the prune list as the
per-line part.
