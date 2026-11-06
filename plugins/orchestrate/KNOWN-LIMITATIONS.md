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
| 2 | A finished agent's **final output can be lost** before the idle transition. | Read-only personas write their result to disk as their final action (a Write tool whose scope, the minted result path, is stated in the brief); the router reads it **from disk**, so nothing depends on the final message arriving (ADR-0014). |
| 3 | `SendMessage` to an **idle agent no-ops** instead of replaying/re-engaging. | The result is already a durable file — the router never needs to re-fetch it from the agent. If the file is absent, the dispatch simply re-runs (reground keys on the file's presence). |
| 4 | Idle pings (`{"type":"idle_notification","idleReason":"available"}`) are **noisy and content-free**. | The router polls the scoped result path + its `<!-- orchestrate:complete -->` sentinel for completion, so idle pings are irrelevant to control flow. |

Net: a dispatched read-only agent (researcher, planner, verifier) can complete
and have its result silently dropped by the channel, and orchestrate still
recovers it, because the result lives on disk, not in the notification. A
writer's result is its commits on its worktree branch, which the router reads
from git the same way.

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
  reground board as authoritative, telling the router to **re-invoke the orchestrate skill**
  (compaction re-injects invoked skill bodies truncated at ~5k tokens, so the post-compaction
  router brain is otherwise a stump).
- **Timing** — the router and `/orchestrate:status` surface the cheap moment: a closed lane
  with a quiescent board, where everything durable is on disk. When the session is long, they
  prompt the operator to run `/compact keep the goal and open lanes; the board on disk is
  authoritative` (check fill with `/context`). The operator stays the trigger; orchestrate
  contributes the timing judgment.

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
why the shared-checkout floor resolves the checkout from the payload's `cwd`; a
hook bug of that class shipped green through hundreds of unit assertions and
fell over in the first minutes of live dispatch. Budget a live pass before
calling hook changes done.

## Codex-specific (codex-cli 0.142.1)

Since 0.9.0 (ADR-0040) Codex gets the skill and one persona TOML per agent, with
no hooks; personas are dispatched natively. On Codex the shared-checkout floor
and every other rule are prose in the briefs.

| # | Codex behavior | Status |
|---|----------------|--------|
| 1 | Model IDs are accepted per account and go stale: on Codex 0.166.0 with a ChatGPT account, `gpt-5.5`, `gpt-5.4`, and `gpt-5.4-mini` were all rejected. Effort `max` was accepted. | **By design (ADR-0041).** The plugin ships no Codex model ID. Every role inherits the parent session's model unless the operator sets `ORCHESTRATE_STANDARD_MODEL` / `ORCHESTRATE_ECONOMY_MODEL` before installing; effort passes through unchanged. |
| 2 | `sandbox_mode` is coarse (`workspace-write`); `writable_roots` is **additive** (adds writable dirs, never subtracts source) and is ignored in `read-only` mode. | **Live limitation.** Every persona that writes or runs anything compiles to `workspace-write`; the narrower scope (a researcher's result file, a verifier's verdict) is the brief's prose, as on every harness. |

`docs/notes/codex-support.md` records the earlier Codex enforcement work that
ADR-0040 removed.
