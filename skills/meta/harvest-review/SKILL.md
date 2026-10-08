---
name: harvest-review
description: Adversarial fresh-context review of an edges-library branch before it ships. Judges each edge on whether it is an edge at all, whether it is already covered, and whether it is the shortest form that keeps the incantation. Invoked by the harvest skill, not by users.
user-invocable: false
context: fork
agent: general-purpose
argument-hint: "<branch> <skill-path> round <n> [prior <verdict-path>] + observations | branch <branch> round <n> [prior <verdict-path>] | diet <branch>"
---

# Harvest review

You did not write this and you do not know who did. Your job is to keep the
edges library sharp and small. The argument names a branch of
`https://github.com/ajilty/agentic` and a scope; clone the branch into
scratch and read `plugins/edges/CONTRIBUTING.md` for the rules you are
enforcing. The harvest skill runs several of you in parallel, one per skill
file the branch changes plus one for the branch, so stay inside your scope:
another reviewer covers the rest. The argument also carries `round <n>`;
from round 2 on it adds `prior <verdict-path>`, the previous verdict for your
scope (see Verdict). Round 1 has no prior.

- `<branch> <skill-path>` (file scope, the default): the path is one
  `SKILL.md` the branch changes, and the rest of the argument is the source
  observation behind each edge that landed in it. Diff only that file
  (`git diff origin/main...HEAD -- <skill-path>`) and judge its edges against
  their observations: an edge that drifted from what was observed is a
  defect. Read the **whole** file, not just the diff: redundancy hides in the
  parts that did not change. Read `working-with-mcp-connectors` for
  question 2 only; do not review other changed files.
- `branch <branch>`: no per-edge verdicts. Run the branch-level checks below.
- `diet <branch>`: unchanged, see Diet branches. A diet touches one skill,
  so it runs as a single instance with no fan-out.

## Five questions, per edge

1. **Is it an edge?** Would a docs lookup have answered it? Does it carry a
   symptom, a cause, and something runnable? A tip, a preference, or a
   restatement of vendor documentation is `not-an-edge`.
2. **Is it already covered?** In this skill, or in
   `working-with-mcp-connectors` for anything tool-agnostic (silent empties,
   dead-token servers, serialization limits, filter probes). Name the covering
   bullet. If the new text adds only a measurement or a verbatim string, the
   verdict is `compress` into that bullet, not a new one.
3. **Is it the minimum viable edge?** Write the shortest version that keeps
   every incantation, verbatim string, and correction. If yours is materially
   shorter, the verdict is `compress` and your text is the proposal. Repeated
   framing across bullets ("no error, no warning, indistinguishable from a
   real zero") is the usual excess.
4. **Does the description follow the template?** Surface, "Load before the
   first call", operation areas, user-utterance cues, 400 characters hard cap
   (CONTRIBUTING). Any error string, field name, or response shape in it is a
   `compress` into the body; over 400 characters is a defect.
5. **Is the decay tag right?** Apply the CONTRIBUTING decay-tag test to the
   observation's fix. A bullet that only corrects the model's own call
   without `<!-- decays: model -->`, or a tagged bullet whose fix works
   around the tool, is a `compress` whose text adds or drops the tag. Only
   tag when the observation shows the fix; untagged is the safe default.

Also check, in your file: redaction (any org, person, tenant, hostname,
dated incident), a correction that left the old claim standing anywhere in
the file, and a generic pattern written only in the vendor skill.

## Branch scope

These need the whole branch, and exactly one reviewer owns them. Diff the
whole branch against `origin/main` and check:

- **Cross-file duplicates**: the same edge, or one cause, written in two
  changed files (typically a vendor skill and `working-with-mcp-connectors`).
  Name both bullets and which one keeps it.
- **Misfiled edges**: an edge whose operation area lives in a different
  skill than the one it landed in.
- **Identity leaks** across the whole diff, commit messages and PR body
  included, not only skill bodies.
- **Commit body** lists every edge on the branch, and nothing dropped.
- **Version bump**: `plugins/edges/.claude-plugin/plugin.json` is bumped
  per CONTRIBUTING.
- **Description caps**: `bash plugins/edges/tests/test_descriptions.sh`
  passes.

Report each as a finding naming the skill file it lands in, or `branch`
for the commit message, PR body, identity leaks outside skill files,
`plugin.json` version, and description caps, so the harvest skill can route
it to that scope's revision.

## Diet branches

A diet adds nothing, so the four questions apply to what was *removed*, not
added. Run the author's proof yourself rather than trusting the PR body:
extract the backtick-quoted tokens and every number from `origin/main`'s copy
and the branch's, diff them, and check each missing item against the prune
list. Anything missing and unlisted is a defect. Then judge each listed prune
with question 1: a pruned incantation, verbatim error string, or correction
of a live claim is `restore`; a pruned docs restatement is `accept`. A prune
of a `decays: model` bullet is `accept` only when its prune line cites
evidence that the current model gets it right unaided; "newer model" alone
is `restore`. A merge that put a tag on a bullet carrying untagged content
is a defect. Check
the description follows the template and stays under 400 characters, and that
every string it dropped exists in the body.

## Verdict

**Report everything you see the first time.** The author gets two revision
rounds; a later round only checks that the earlier verdict was applied and
that the fixes introduced nothing new. A finding you could have raised in
round one and raise in round three costs the human a decision. In round 2 or
later, read the prior verdict at `<verdict-path>`: confirm each of its items
landed, and flag only regressions the fix introduced. No fresh nits.

Start with your scope (the skill path, `branch`, or `diet`). Then one line
per edge: `accept`, `compress: <your text>`, `redundant: <covering bullet>`,
or `not-an-edge: <why>`; on a diet, one line per prune: `accept` or
`restore: <why>`; in branch scope, one line per finding with its file or
`branch`, or `accept`. Then any file-level findings. Be specific enough that
the author can apply it without judgment. Do not edit the branch.
