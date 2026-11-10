---
description: "Operator status update: glanceable, zoomed-out to detail, surfaces only what needs you."
---

# Orchestrate status

Give the **operator** a re-entry status update for the current orchestrate run, read **only
from durable disk state** so it survives a context switch or compaction. Do not rely on
conversation memory. This is a **read-only projection: write nothing** (no `STATUS.md`; the one exception is
reground's own archive of 0.8.x run state, which it announces).

Gather, keeping raw output OUT of your reply (glance, don't dump):

- `ledger.sh reground`: open lanes, the `goal` anchor (north star + plan pointer), and any
  ambiguous-writer halt.
- `ledger.sh metrics`: shipped / dispatches / forks / rejects / verify_coverage / denials /
  model_mix / unjournaled_work (pace + health).
- `.agents/runs/orchestrate/board.jsonl`: per-lane `intake`(tier)/`dispatched`/`returned`/
  `verdict`/`fork`/`decision`/`done`, and the run-level `goal` event.
- Only for lanes that are active or need input: the ticket file behind them
  (`tickets/<ticket>/fork.md`, verdicts, `work-item.md`) and the writer worktree's commits-ahead.
- `.agents/runs/orchestrate/eval/feedback.jsonl`: ts of the last feedback row (if any),
  to spot a feedback gap.
- Runtime freshness: read the `version` from the executing plugin's
  `.claude-plugin/plugin.json` (one level above `bin/` when `ledger.sh` resolves to the
  plugin's `bin/` shim, which `command -v ledger.sh` shows; three levels above
  `skills/orchestrate/runtime/` otherwise) and compare it against the newest
  version directory installed for this plugin (Claude Code keeps versioned installs
  side by side, e.g. `~/.claude/plugins/cache/<marketplace>/orchestrate/<version>/`).
  A long-lived session keeps executing its loaded copy after `plugin update`.

Render top-down and glanceable, with these emojis:
🎯 goal · 📋 plan · 🌳 lanes · 🙋 needs you · ⏭️ next · 📄 file;
pace 🟢 moving · 🟡 slow · 🔴 stalled; lane ✅ done · 🔄 running · 🚧 blocked · ⏳ queued · ❌ rejected(retrying).

1. 🎯 **Headline**: the goal (from the `goal` event), pace (🟢/🟡/🔴 from event recency +
   done-ratio), progress (`N done / M lanes`), and 📋 the plan pointer (spec/ADR path).
   When `metrics` shows `denials>0`, add one line, `⛔ N denials (who and command)`, from
   the board's `denied` events: the shared-checkout floor stopped a discarding git command
   aimed at the primary checkout. `persona` is the agent that ran it (`-` is a main session,
   which may be the operator's own work outside the run). When `metrics`
   shows `unjournaled_work>0`, add one line: `⚠️ N results with no matching dispatched
   event`; the router skipped the journal, so model_mix and coverage undercount.
2. 🌳 **Lanes**: a tree, one node per ticket with its status glyph; parallel lanes are
   siblings; writer lanes show worktree commits-ahead. When the `dispatched` events carry
   `model`/`effort`, show them inline per lane (e.g. `implementer sonnet/medium`), so the operator
   can see horsepower was right-sized.
3. 🙋 **Needs you**: render this section **only if non-empty**: halted `DECISION_FORK`s,
   clarify-halts, prod changes waiting for the operator's confirmation (a `fork` row whose
   `fork_id` is `prod-ack:<target>` with no matching `decision`), `INCONSISTENT_ORACLE`,
   an in-flight actuator after an interruption, and a reground HALT (a lane worktree the
   board lost). An `OPEN WRITER ... branch=unknown` is a running lane 🔄, not a halt; an
   `OPEN LANE` row is a parked lane shown under Lanes. Each is one line (the ask) + 📄
   pointer to the ticket
   file. If nothing is pending, omit the section and say `nothing needs you`.
4. ⏭️ **Next**: what's coming, from the plan's remaining tasks + current lane states.

Edge cases: no board → `no orchestrate run in this repo`. A clean board with a `goal` and no
open lanes → report it, but add the ADR-0020 caveat: a clean board is **not** "done" until the
plan is complete. Keep it skimmable; drill-in happens conversationally if the operator asks.

When the board is quiescent (no in-flight dispatch) **and** the session has grown long, add one
footer line: `💡 clean boundary: good time for /compact keep the goal and open lanes; the board
on disk is authoritative`. Compaction is operator-triggered only; this surfaces the cheap moment.

When `done` lanes postdate the last feedback row (or `eval/feedback.jsonl` has none), add one
footer line: `💬 N lanes shipped since the last feedback row; capture at the next goal boundary
or wrap-up (/orchestrate:feedback)`. Runs that roll goal-to-goal never reach wrap-up, so the
row never lands (ADR-0028).

When the executing runtime's version is older than the newest installed version, add one
footer line: `🔄 runtime <executing> < installed <newest>: /reload-plugins (or restart) to
apply`. The one-shot nudge after `plugin update` is missable; this is the persistent signal.

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
