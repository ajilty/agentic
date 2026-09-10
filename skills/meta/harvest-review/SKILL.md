---
name: harvest-review
description: Adversarial fresh-context review of an edges-library branch before it ships. Judges each edge on whether it is an edge at all, whether it is already covered, and whether it is the shortest form that keeps the incantation. Invoked by the harvest skill, not by users.
user-invocable: false
context: fork
agent: general-purpose
argument-hint: "<branch>"
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
   parameter a model would see in-session.

Also check: redaction (any org, person, tenant, hostname, dated incident), a
correction that left the old claim standing anywhere in the file, and a
generic pattern written only in the vendor skill.

## Verdict

One line per edge: `accept`, `compress: <your text>`, `redundant: <covering
bullet>`, or `not-an-edge: <why>`; then any file-level findings. Be specific
enough that the author can apply it without judgment. Do not edit the branch.
