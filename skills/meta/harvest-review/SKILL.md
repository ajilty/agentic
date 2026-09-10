---
name: harvest-review
description: Adversarial fresh-context review of an edges-library branch before it ships. Judges each edge on whether it is an edge at all, whether it is already covered, and whether it is the shortest form that keeps the incantation. Invoked by the harvest skill, not by users.
user-invocable: false
context: fork
agent: general-purpose
argument-hint: "<branch> | diet <branch>"
---

# Harvest review

You did not write this and you do not know who did. Your job is to keep the
edges library sharp and small. The argument is a branch of
`https://github.com/ajilty/agentic`; clone it into scratch, diff it against
`origin/main`, and read `plugins/edges/CONTRIBUTING.md` for the rules you are
enforcing. Read the **whole** target skill, not just the diff: redundancy
hides in the parts that did not change.

## Four questions, per edge

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
4. **Does the description carry triggers, not content?** Flag any description
   sentence that summarizes the body instead of naming a string, tool, or
   parameter a model would see in-session. Over 1,536 characters is a defect
   (the listing truncates there, silently); over 600 is a `compress`.

Also check: redaction (any org, person, tenant, hostname, dated incident), a
correction that left the old claim standing anywhere in the file, and a
generic pattern written only in the vendor skill.

## Diet branches

A diet adds nothing, so the four questions apply to what was *removed*, not
added. Run the author's proof yourself rather than trusting the PR body:
extract the backtick-quoted tokens and every number from `origin/main`'s copy
and the branch's, diff them, and check each missing item against the prune
list. Anything missing and unlisted is a defect. Then judge each listed prune
with question 1: a pruned incantation, verbatim error string, or correction
of a live claim is `restore`; a pruned docs restatement is `accept`. Check
the description landed under 600 characters and still names the triggers.

## Verdict

**Report everything you see the first time.** The author gets two revision
rounds; a later round only checks that the earlier verdict was applied and
that the fixes introduced nothing new. A finding you could have raised in
round one and raise in round three costs the human a decision.

One line per edge: `accept`, `compress: <your text>`, `redundant: <covering
bullet>`, or `not-an-edge: <why>`; on a diet, one line per prune: `accept` or
`restore: <why>`. Then any file-level findings. Be specific
enough that the author can apply it without judgment. Do not edit the branch.
