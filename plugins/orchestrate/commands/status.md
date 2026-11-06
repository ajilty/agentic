---
description: "Operator status update: glanceable, zoomed-out to detail, surfaces only what needs you."
---

# Orchestrate status

Give the **operator** a re-entry status update for the current orchestrate run, read **only
from durable disk state** so it survives a context switch or compaction. Do not rely on
conversation memory. This is a **read-only projection: write nothing** (no `STATUS.md`).

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
- Runtime freshness: read the `version` from the executing runtime's `plugin.json`
  (three levels above the `ledger.sh` you just ran) and compare it against the newest
  version directory installed for this plugin (Claude Code keeps versioned installs
  side by side, e.g. `~/.claude/plugins/cache/<marketplace>/orchestrate/<version>/`).
  A long-lived session keeps executing its loaded copy after `plugin update`.

Render top-down and glanceable, with these emojis:
🎯 goal · 📋 plan · 🌳 lanes · 🙋 needs you · ⏭️ next · 📄 file;
pace 🟢 moving · 🟡 slow · 🔴 stalled; lane ✅ done · 🔄 running · 🚧 blocked · ⏳ queued · ❌ rejected(retrying).

1. 🎯 **Headline**: the goal (from the `goal` event), pace (🟢/🟡/🔴 from event recency +
   done-ratio), progress (`N done / M lanes`), and 📋 the plan pointer (spec/ADR path).
   When `metrics` shows `denials>0`, add one line, `⛔ N denials (persona and command)`, from
   the board's `denied` events; the shared-checkout floor stopped a discarding git command
   in the primary checkout, so that persona needs its worktree context. When `metrics`
   shows `unjournaled_work>0`, add one line: `⚠️ N results with no matching dispatched
   event`; the router skipped the journal, so model_mix and coverage undercount.
2. 🌳 **Lanes**: a tree, one node per ticket with its status glyph; parallel lanes are
   siblings; writer lanes show worktree commits-ahead. When the `dispatched` events carry
   `model`/`effort`, show them inline per lane (e.g. `verifier opus/max`), so the operator
   can see horsepower was right-sized.
3. 🙋 **Needs you**: render this section **only if non-empty**: halted `DECISION_FORK`s,
   clarify-halts, prod changes waiting for the operator's confirmation, `INCONSISTENT_ORACLE`,
   reground ambiguous-writer halts. Each is one line (the ask) + 📄 pointer to the ticket
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
