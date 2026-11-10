# Progress page rules

Router reference (core: `../SKILL.md`, loop step 5; command: `/orchestrate:status`). How a run's progress page is offered, created, refreshed and checked. The template is `status-page.html` beside this file.

## Progress page (optional; inline stays the default)

A run the operator keeps re-entering can carry a live progress page beside the
inline report. The page is for the operator as a reader, not a console: same
register as this command, outcomes first, no ticket ids or persona names.

**Offer it exactly once per goal.** When the run has crossed any of: tier T2,
more than one lane, or a goal older than a day, end the inline status once
with: "This run is big enough for a progress page that stays current; want
one?" Journal the answer either way so reground never re-offers:
`ledger.sh append '{"ticket":"<goal ticket>","event":"decision","fork_id":"status-page","note":"<accepted|declined>"}'`.
The goal ticket is the first `intake` ticket after the current `goal` event;
every later `status-page` row uses that same ticket. No row on the board means
not yet offered; a row means never offer again this goal.

**Create on accept.** Ask the operator's timezone once (skip if already
journaled). Copy `references/status-page.html` (this skill's directory) to
`.agents/runs/orchestrate/status.html`, the canonical copy, and fill its DATA
block from the board: lanes and verdicts into streams and the window, `fork`
rows awaiting a `decision` into "Yours now", `decision` rows into "Settled"
with attribution, `done` pace into the estimate. The template's top comment is
the field contract. Publish per the harness note below, then journal the page
on the goal anchor:
`ledger.sh append '{"ticket":"<goal ticket>","event":"decision","fork_id":"status-page","note":"accepted: <url> tz=<zone> cadence=<hourly|on-change|...>"}'`
(the latest `status-page` decision row wins; a cadence change is a new row).

The canonical copy belongs to the current goal: when a new goal starts in the
same repo and gets its own page, the prior goal's published URL stays live but
its canonical file is overwritten; copy it into the run's records first if the
goal is worth keeping locally.

**Refresh** on every status invocation, on every lane state change, and on
every liveness re-entry tick (SKILL "The loop" step 5) past the cadence. The
lane-change refresh is the main path: never end a turn that journaled a lane
state change without refreshing the page (`ledger.sh` prints a reminder on
each such write while the goal's page is on). Several changes in one turn take
one refresh, after the last write. The timer is only the backstop for quiet
stretches; it fires least when the run is busiest. Cadence is hourly by
default; the operator can set it in plain words.

A refresh rebuilds the page; it never patches it. In this order:

1. **Gather.** Read the board (`ledger.sh reground`, open forks and decisions,
   verdicts, `done` rows), git (what merged, commits ahead per lane), and CI
   for anything the page will call green. Seeing a check queued is not seeing
   it pass.
2. **Rebuild every field above the history** from what you gathered: headline,
   lead, changed strip, tiles, needs, window, streams, calls, estimate. Each
   needs, pending and window entry carries a `ref` naming what the journal
   knows it as (a ticket, `plan:<ticket>`, `fork:<ticket>/<fork_id>`, or
   `none:<why>`; the template's top comment has the forms). An entry is shown
   done or live only when the board has its `done` row or an approved outcome
   verdict AND you have seen its check green; merged work whose check has not
   run stays built or waiting. An ask is listed only while its fork has no
   decision, and every ask is a journaled fork. One finish date, the estimate
   card's, everywhere it appears.
3. **History last.** Append one entry per change (newest first) only after the
   rest is rebuilt. A refresh that touches only the stamp and the history is
   the failure this order exists to prevent: the stamp stays fresh while the
   page goes stale.
4. **Stamp at publish.** Set `updated` (operator's timezone, always) and
   `updated_at` (the same moment in UTC, from `date -u +%FT%TZ` run now, the
   ledger's own format; never a hand-written offset). Keep `cadence_minutes`
   equal to the backstop interval (60 unless the operator set another; an
   on-change cadence still promises the 60-minute backstop).
5. **Check, then publish.** Run `ledger.sh page-check --publish
   .agents/runs/orchestrate/status.html` and fix everything it prints. On
   Claude Code a hook runs the same check on the publish and refuses a page
   that fails, naming each failure; fix the page, never route around the hook
   by publishing a copy. The page draws its own
out-of-date banner once `updated_at` is older than twice `cadence_minutes`,
so a missed refresh shows instead of passing for current.

**Rewrite, never extend.** The top of the page is rewritten from the board as
it stands on every refresh: the headline is one outcome sentence of what is
true now, the lead says only what comes next, and the changed-since strip
holds only this refresh's news. Last refresh's news moves to history, not into
the lead. Each field has a word budget in the template's top comment; the
check in step 5 reports any field over it. A page that keeps growing at the
top turns into a wall of text the operator stops reading.

A correction is its own history entry marked "(corrected)", never a silent
edit; an accepted red is restated each refresh ("you accepted"). Estimates
live only in the estimate card, labelled as your read, never mixed into
measured state. Prose rules carry over from this command; "Calls that are
yours" is first-class, attributed ("Your decision", "Your standing rule",
"Made for you, reversible on your word").

What the check cannot see: whether a check really ran green (it sees the
board's `done` row, so journal `done` only after you have seen it), an entry
marked `none:`, a stream item with no `ref`, the displayed `updated` time
against `updated_at`, and a refresh that changes one word and no more. Keep
`none:` for things the board truly does not track. The check is a floor; the
rebuild order above is the job.

A page created before 0.9.6 lacks `updated_at` and `ref`s; on its next refresh, move it
onto the current template (copy the template, carry DATA across, add the new
fields and a `ref` on every needs, pending and window entry) so it gains the
banner, the budgets and the checks. The publish hook refuses it until then.

**Harness note.** On Claude Code, publish with the Artifact tool: first
publish creates the page (favicon, description), every refresh republishes to
the journaled URL, and a session that did not create the page must Artifact-read
that URL once before it can republish (the refusal hands back the live
version; merge into it). A session-bound schedule (cron or wakeup) dies with
its session: re-arm the refresh schedule on reground when the goal carries an
accepted `status-page` row. On a harness with no artifact surface, the
canonical file is the page; say where it is.
