# The progress page is checked against the journal at publish, by a hook

## Context

ADR-0040 turned workflow rules into prose and kept two hooks, on the test that
a hook must check a fact, not police a workflow. The optional progress page
(0.9.5) was governed by prose alone: refresh on change, rewrite the top, keep
the stamp current.

On 2026-11-09 and 10 a live page was wrong for about a day while its stamp
stayed fresh. Each hourly refresh bumped the stamp and appended a history
line; the headline, lead, asks, timeline, stream states, tiles and decisions
stayed as written the night before. Finished work read as waiting on the
operator, two finish dates sat on one page, and a check was called green
before its run had fired. The refresh instruction did say to edit those
sections. On quiet ticks the router took the cheap path and kept taking it.

Two lessons: a freshness stamp does not show that content is fresh, and an
instruction that was present and skipped is not fixed by a firmer instruction.

## Decision

A third hook, `check-status-page.sh`, runs on every publish of a run's
canonical page (`.agents/runs/orchestrate/status.html`) and refuses it when
`ledger.sh page-check --publish` fails. The check is deterministic and reads
only the page and the board:

- an entry shown as upcoming, or as waiting on the operator, that the board
  records as done or answered;
- an entry shown done or live with no `done` row or approved verdict;
- finish dates in the headline, lead, tiles or timeline that disagree with
  the estimate card;
- a stamp that is not the publish time;
- journal events since the last checked publish with nothing changed on the
  page except the stamp and the history;
- page code that does not parse.

Entries carry a `ref` (a ticket, a fork, or `none:<why>`) so the check can
tie them to the board. That is structure for a deterministic consumer, the
case the repo reserves structure for.

This fits ADR-0040's test: it is a fact check of one artifact against the
journal, it needs no arming, and it does not judge how the work was done.

## Considered options

- **Firmer prose only**: rejected; prose was present and skipped.
- **A check the router is told to run, no hook**: kept as step 5 of a refresh
  so failures surface early, but not relied on, for the same reason.
- **A freshness banner alone** (0.9.6's first cut): kept, but it catches a
  page nobody refreshed, not one refreshed badly.
- **The page reads the board itself**: a larger change (a data store behind
  the page, a second copy of state); deferred.

## Consequences

- The hook count is three; ADR-0040's "two survive" is amended here.
- A page built before 0.9.6 has no refs and is refused until it is moved onto
  the current template.
- The check trusts the board. `none:` entries, stream items without a ref, and
  a `done` row journaled too early pass. KNOWN-LIMITATIONS says so.
- Claude Code only; it needs `jq`, and skips the parse check without `node`.

## Amends

0040 (its hook count: three, not two).

Status: active
