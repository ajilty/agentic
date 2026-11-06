---
name: research
description: Read-only investigation with confirmed-vs-inferred labeling and durable findings.
disable-model-invocation: true
---

# Research

Investigation is read-only reduction: read much, return little, change nothing.
The output feeds a decision or a plan, so its quality is measured by what a
planner can safely build on it.

- **Label every finding**: confirmed (you ran or read the primary source; name
  it) versus inferred (your read; say so). A silently wrong elimination of an
  option poisons everything downstream, so uncertainty on an elimination is
  worth surfacing loudly.
- **Provenance rides along**: where each fact came from (file:line, command
  output, doc URL), so a reader can re-verify without redoing the sweep.
- **Two flavors, keep them separate**: a sweep (mechanical inventory; a list or
  map the reader consumes directly) and judgment (findings that eliminate
  options or feed a spec). Name which one you were asked for; do not let a
  sweep quietly grow conclusions.
- **Sharp conclusions**: end with what is now known, what remains unknown, and
  the one or two decision forks the findings expose. No raw dumps.
- **Durable artifact**: write findings to a file the next phase can cite, not
  only into conversation.

## Web and document research

Source-based work adds a method on top of the labeling and provenance above.

- **Split first.** For a broad question, list the key questions that do not
  overlap and together cover the objective, and state what each needs. A
  dispatcher can give independent ones to separate researchers.
- **Search loop.** Find what is missing, search with short varied queries, read
  the full page behind anything you will rely on, and repeat.
- **Stop** when the key questions are answered with sources, when no new
  information appears, or at about 15 search or fetch calls for one question.
  Report the remainder as a gap.
- **Weigh sources.** Prefer the primary source to an aggregator, separate
  confirmed fact from speculation, show both sides when sources conflict, and on
  recent topics trust current sources over memory.
- **Report per key question**: takeaway, cited findings, inferences, gaps. A
  claim with no source moves to gaps.
