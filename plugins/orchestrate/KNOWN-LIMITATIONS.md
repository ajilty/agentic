# Known limitations

orchestrate runs **on** the host harness's subagent machinery (Claude Code's
`Task`/`Agent` dispatch, its notifications, its worktree isolation). A few harness
behaviors are outside a plugin's reach — orchestrate cannot patch them, so instead
it **compensates by design** and treats the harness channel as untrusted. They are
listed here so you can tell a harness behavior apart from an orchestrate bug, and
so you don't file the former as the latter.

If you hit one of these, it is **expected**: orchestrate already defends against
it. File a bug only if the *compensation* fails (e.g. a read-only result is lost
even though no `findings/<slug>.md` was ever written, or a writer mutated the
shared checkout) — see [the bug-report template](../../.github/ISSUE_TEMPLATE/bug_report.yml)
and the "is this a harness limitation?" classifier there.

## Subagent result / notification channel (Claude Code)

Observed on Claude Code 2.1.x. The substantive result of a dispatched subagent is
delivered through a notification channel that can be unreliable:

| # | Harness behavior | How orchestrate compensates |
|---|------------------|-----------------------------|
| 1 | A task-notification can carry the **wrong agent's label** (result attribution is wrong). | Every dispatch is keyed by a router-minted `dispatch_id` baked into the result **filename**; the router reads the exact path it minted, never a notification label (ADR-0014). |
| 2 | A finished agent's **final output can be lost** before the idle transition, and the harness delivers **at most one** handback per agent (a second `SubagentHandback` is refused: "your report was already delivered"). | **Every** persona writes its result to disk as its final action: read-only personas via their Write tool, and since 0.9.4 the implementer and actuator too (`tickets/<ticket>/results/<dispatch_id>.md` with the `<!-- orchestrate:complete -->` sentinel; the actuator writes via its shell). The router reads completion **from disk**, so nothing depends on any message arriving (ADR-0014). Measured 2026-11-08: a builder's refused second handback left the router waiting on chat overnight; the writer result file closes that exact gap. |
| 3 | `SendMessage` to an **idle agent no-ops** instead of replaying/re-engaging. | The result is already a durable file — the router never needs to re-fetch it from the agent. If the file is absent, the dispatch simply re-runs (reground keys on the file's presence). |
| 4 | Idle pings (`{"type":"idle_notification","idleReason":"available"}`) are **noisy and content-free**. | The router polls the scoped result path + its `<!-- orchestrate:complete -->` sentinel for completion, so idle pings are irrelevant to control flow. |

Net: any dispatched persona can complete and have its report silently dropped
by the channel, and orchestrate still recovers it, because the result lives on
disk, not in the notification; a writer's commits on its worktree branch
corroborate its result file. The router also never *waits* on the channel: it
ends no turn with work in flight and nothing scheduled, scheduling its own
re-entry instead (on Claude Code `ScheduleWakeup`, else a cron at ~15 minutes;
see the liveness note in `references/agents.yaml`) and routing any dispatch
older than ~15 minutes with no `returned` row from its result file or worktree.

## Native worktree isolation cuts from `origin/HEAD` (Claude Code)

The harness's `isolation: worktree` cuts each writer's tree from the repo's
default branch (`origin/HEAD`), or from the current local `HEAD` when the
project sets `worktree.baseRef: "head"`. A plugin cannot set that. If
`origin/HEAD` points at a stale branch, writers start from the wrong base. The
router checks at intake that the harness's base equals the goal's journaled
base and, on a mismatch, stops with the fix
(`git remote set-head origin <base>`, or the setting) before dispatching any
writer. Separately, the
shared-checkout floor (ADR-0013) stops discarding git commands in the primary
checkout if a writer ever ends up there.

## Agent teams (Claude Code)

Claude Code's experimental **agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
off by default) turns dispatched subagents into peer-messaging teammates, the
opposite of orchestrate's isolated dispatch-and-return personas whose only
channel is disk (ADR-0012). The router passes `isolation: worktree` on every
implementer dispatch and takes no control signal from a persona except its
result file. Prefer leaving agent teams off in repos where you run orchestrate.

## Agent-definition `model:` frontmatter (Claude Code)

Earlier Claude Code versions ignored a plugin agent's `model:` frontmatter, so
every persona silently inherited the parent's model (issues #44385 / #43869).
That is fixed upstream: on 2.1.318 the compiled `model:` binds, and it binds
upward too (a haiku main loop dispatching an agent file that names opus ran
opus). So the premium personas (planner, verifier) carry no `model:` and
inherit the main loop, and the router clamps the standard and economy aliases
at dispatch: a `model` passed on the call outranks the agent file and takes an
alias only (ADR-0041). The ledger journals what was passed on the `dispatched`
event; `metrics model_mix` shows what was actually spent.

`effort:` frontmatter is documented to bind but not re-tested: effort, unlike
the model, is not self-reportable.

## Compaction cannot be triggered or timed by a plugin (Claude Code)

Auto-compaction fires near the model's context limit, often mid-lane — the worst moment.
No plugin/model path can trigger `/compact` (user-only), and the documented early-trigger
env vars (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` + `CLAUDE_CODE_AUTO_COMPACT_WINDOW`) are
**not production-grade** as of v2.1.2xx: shell-export only (a `settings.json` `env` block is
silently ignored, issue #63186), unreliable on 1M-context models (#53801), and sometimes
inert (#52390, #36381). Verified 2026-07-10.

orchestrate compensates on both sides instead:

- **Recovery** — control state is disk-first and the `SessionStart(compact)` hook injects a
  reground board as authoritative, and a second hook prints the router's core instructions
  back (compaction re-attaches invoked skill bodies truncated at ~5k tokens, or drops them;
  see "What a router holds after a compaction").
- **Timing** — the router and `/orchestrate:status` surface the cheap moment: a closed lane
  with a quiescent board, where everything durable is on disk. When the session is long, they
  prompt the operator to run `/compact keep the goal and open lanes; the board on disk is
  authoritative` (check fill with `/context`). The operator stays the trigger; orchestrate
  contributes the timing judgment.

## What a router holds after a compaction

- **The core comes back; the references do not.** A hook re-attaches the
  router's core instructions after every compaction on Claude Code (measured:
  intact in three of three compacted runs). OpenCode gets no re-attach: its
  plugin is wired to run the same scripts on its compaction event, but that
  event has no documented way to hand their output to the model, and whether
  it fires at all has not been observed. Reference files read earlier are summarized away with the rest
  of the conversation; the core tells the router to read each again at its
  step, and that re-read is still the router's choice.
- **Codex has no start command and no compaction hook wired.** There the core
  reaches the router only as the skill, and the harness's own rules decide
  what survives a compaction.
- **A start command typed mid-conversation injects the core once.** It is not
  re-injected on later turns; the compaction hook covers the gap after a
  compaction, nothing covers a very long uncompacted session drifting.
- **The injected command must be allowed to run.** Its exact command line is
  pre-approved in the command's frontmatter. A permission rule that asks or
  denies on it wins over that approval, and a blocked or failed injection
  aborts the whole command before the model sees it: the operator gets an
  error, not a degraded run. Invoke the `orchestrate` skill directly then.
- **The re-attach reaches every compacted session in a repo with a driven run**,
  not only the router: a hook cannot tell which session is driving, and the
  board records none. A session doing other work there gets the core (about
  2,500 tokens per compaction) headed by a line telling it to ignore it. A
  board with no goal, intake or dispatch row prints nothing.
- **The re-attach sits close to the harness's 10,000-character cap on hook
  output** (about 9,850 with its JSON escaping). The printed core embeds the
  install path, so a path about 150 characters longer than usual would push it
  over, and the harness would then hand the router a file pointer instead of
  the text. Tests hold the line at this checkout's path.
- **After a compaction the core can arrive more than once**: from the hook,
  from the harness re-attaching the skill, and from the first part of the
  start command. The core text is the same in each; the hook copy adds a line
  saying who it is for.

## Progress-page mechanics (Claude Code artifacts)

The optional status progress page (`/orchestrate:status`, "Progress page")
publishes through the harness's artifact surface, which has edges a plugin
cannot change:

- **Republish needs a prior read.** A session that did not create the page
  cannot blind-publish to its URL: the publish is refused and hands back the
  live version. The command compensates: read once, merge, republish; the URL
  survives on the goal anchor (`status-page` decision row), not in any
  session's memory.
- **Session-bound schedules die with the session.** A refresh cron or wakeup
  armed in one session does not outlive it. Reground re-arms the schedule
  whenever the goal carries an accepted `status-page` row.
- **The page cannot refresh itself.** It is a snapshot republished by the
  router in its own turns, never a live view. Refreshes ride lane state
  changes, with the timer as a backstop that only fires when the session is
  idle; the page draws an out-of-date banner itself when its last update is
  older than twice the promised interval, so a lapse is visible, not hidden.
- **The publish check sees the journal, not the world.** It refuses a page
  that contradicts the board or itself, but it trusts the board: an entry
  marked `none:`, a stream item with no `ref`, and a `done` row journaled
  before its check was really seen all pass. Whether CI is green is not
  something it can read. Its stale-page tripwire catches a refresh that
  touches only the stamp and history; one changed word passes it. The shown
  `updated` time is not compared with `updated_at`. A page published from a
  copy or a symlink under another name is not checked. It runs only on Claude Code (the
  one harness with an artifact surface), needs `jq` to read the publish call,
  and skips the code-parse check when `node` is absent.
- **Size.** The page is one self-contained file and must stay under the
  artifact size limit; the changelog grows per refresh, so a very long run
  should prune history older than the goal into the repo's run records (note
  the pruning as its own changelog entry).

On a harness with no artifact surface, none of this applies: the canonical
`.agents/runs/orchestrate/status.html` is the page.

## Credential confinement is yours (all harnesses)

orchestrate cannot confine the actuator's credentials from inside the harness.
Scope the actuator lane's credentials to the target it changes, and a
live-environment oracle's credentials to the verifier, in your deployment.
Before an actuator touches anything tagged `prod`, the router asks you.

## Testing the plugin live (gotchas for the next tester)

Learned running 4 parallel real-world scenarios (headless `claude -p --plugin-dir`,
sonnet, isolated scratch repos) on 2026-07-02. None of these are orchestrate bugs,
but all three will confuse you if you don't know them going in:

| # | Behavior | What to do about it |
|---|----------|---------------------|
| 1 | **Task-list leakage into the parent session (CC).** Driving `claude -p` scenario sessions from *inside* a Claude Code session leaks the children's task items (TaskCreate) into the parent's task list via inherited session env — you'll see phantom "Implementer: …" / "Verifier: …" tasks that belong to dead child sessions and never complete. | Cosmetic; ignore or run the fleet from a plain shell. Don't chase the "stuck" tasks — their sessions are gone. |
| 2 | **A shared `--plugin-dir` is shared mutable state.** Agents under test can edit the plugin's own files, hook scripts included. Observed live: a router patched a hook script mid-run to get past a false deny; with parallel scenarios sharing the dir, the patch leaked across scenarios and into the plugin repo's working tree. | Give each scenario its **own copy** of the plugin dir, and `git diff` the real plugin dir after any live run. |
| 3 | **Managed/remote environments carry OAuth in env, not in `~/.claude/.credentials.json`.** `claude -p` works fine, but any auth gate that only checks the credentials file (as `have_live_auth` did) makes live tiers self-skip while a hand-run probe succeeds — a confusing split. | Fixed in `tests/integration/lib.sh` (`have_live_auth` now also accepts `CLAUDE_CODE_OAUTH_TOKEN*` env). If you write new live gates, probe capability, not one credential shape. |

Also useful to know: a live fleet catches what unit tests structurally can't.
Under Claude Code a hook's process cwd is not the subagent shell's cwd, which is
why the shared-checkout floor resolves the checkout per statement (tracking `cd`,
`pushd`, subshells, and `git -C` from the payload's `cwd`) rather than its own cwd; a
hook bug of that class shipped green through hundreds of unit assertions and
fell over in the first minutes of live dispatch. Budget a live pass before
calling hook changes done.

## Codex-specific (codex-cli 0.166.0)

Since 0.9.0 (ADR-0040) Codex gets the skill and one persona TOML per agent, with
no hooks; personas are dispatched natively. On Codex the shared-checkout floor
and every other rule are prose in the briefs.

| # | Codex behavior | Status |
|---|----------------|--------|
| 1 | Model IDs are accepted per account and go stale: on Codex 0.166.0 with a ChatGPT account, `gpt-5.5`, `gpt-5.4`, and `gpt-5.4-mini` were all rejected. Effort `max` was accepted. | **By design (ADR-0041).** The plugin ships no Codex model ID. Every role inherits the parent session's model unless the operator sets `ORCHESTRATE_STANDARD_MODEL` / `ORCHESTRATE_ECONOMY_MODEL` before installing; effort passes through unchanged. |
| 2 | `sandbox_mode` is coarse (`workspace-write`); `writable_roots` is **additive** (adds writable dirs, never subtracts source) and is ignored in `read-only` mode. | **Live limitation.** Every persona that writes or runs anything compiles to `workspace-write`; the narrower scope (a researcher's result file, a verifier's verdict) is the brief's prose, as on every harness. |

`docs/notes/codex-support.md` records the earlier Codex enforcement work that
ADR-0040 removed.
