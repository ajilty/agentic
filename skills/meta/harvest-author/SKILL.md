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
- Correcting a live claim: rewrite the bullet to state the current fact, as if
  it had always read that way, and say "corrects" in the commit message. The
  bullet never refers to its own past ("this corrects an earlier note here"):
  that is a diff against a version the model never saw. Where the wrong claim
  is one the model may hold from training, state the negative with its
  evidence. Never leave the old and new side by side.
- A repeat hit (a candidate harvest marked as already covered by a bullet)
  is a fix to the skill, not a new line: if the skill had not loaded in that
  session, the description missed the surface, so widen it within the
  template and the cap; if it had loaded, the bullet failed to prevent the
  failure, so rewrite the bullet so the incantation or the check comes first.
  Say which in the PR body.
- Description: touch it only if the tool surface changed (a new tool family
  or a new user-utterance cue). It follows the CONTRIBUTING template: surface,
  "Load before the first call", operation areas, user cues; 400 characters
  hard cap. Error strings, field names and response shapes never go in it.

**Audit on touch.** Before committing, run the bundled prompt audit on each
skill directory you changed: `/claude-api prompt-audit
skills/knowledge/<skill>` (the path matters; without it the audit covers only
`.claude/` and `CLAUDE.md`). It reads the one file and reports findings with
a confidence level. Fold its high- and medium-confidence findings into the
same commit, each as its own change, unless one would delete an incantation,
a verbatim string, or a number; list them in the PR body under "audit". Flag
items and anything below medium are not applied.

**Diet on touch.** If a skill you changed is over 16 KiB after your edits,
or the audit returned three or more findings on it, give that skill the diet
pass below in the same branch, as a second commit titled `edges(<tool>):
diet`, with the prune list in the PR body. The PR then stays a draft through
`ship` like any diet PR, so the human confirms the prunes once, on merge.
This is the only way a diet runs unprompted: nobody has to remember one.

Then `bash scripts/check.sh` (the full CI mirror; `pre-push` runs it too).
A failure that also reproduces on main is pre-existing only if main's latest
CI run (`gh run list --branch main --workflow tests`) is red on the same
check; otherwise it blocks the PR and is reported, never shipped past.
Commit with an
`edges(<tool>): <edge>` subject, push, and open the PR **as a draft**
(`gh pr create --draft`) with a body listing each edge and its redaction
statement. Return the standard shape.

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

## Mode: diet <skill> [: direction]

No new content. Direction after the skill name ("the auth section", "the
repeat hits on paging") narrows the pass and binds; without it, diet the whole
skill. Read the skill and rewrite it to its minimum viable form:
merge bullets that share a cause, cut repeated framing ("silently, with no
error" once per section, not per bullet), and rewrite the description to
the CONTRIBUTING template (surface, load-before-first-call, areas, user cues;
400 characters hard cap), moving any error string or field name it carried
into the body if the body lacks it. A diet may also **prune**
a bullet that fails the edge test: documented behavior, or tradecraft with no
failure behind it. Never prune an incantation, a verbatim error string, or a
correction of a live claim. Run the prompt audit on the skill first (as in
Audit on touch) and take its findings as input: relative phrasing about the
file's own past, harness mechanics the model already has, and a rule stated
twice are diet material.

Before committing, prove it mechanically: extract the set of backtick-quoted
tokens and every number from the old and new files and diff them. Anything
missing is either restored or named in the prune list; there is no third
option.

Open as a draft PR titled `edges(<tool>): diet` whose body has two lists:
what was merged, and what was pruned with one line of reason each. The prune
list is for a human to confirm before merge, so a diet PR is never marked
ready by `ship`; return the standard shape with the prune list as the
per-line part.
