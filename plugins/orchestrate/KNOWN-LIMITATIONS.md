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
| 2 | A finished agent's **final output can be lost** before the idle transition. | Read-only personas write their result to disk (`results-only` write, hook-scoped) as their final action; the router reads it **from disk**, so nothing depends on the final message arriving (ADR-0014). |
| 3 | `SendMessage` to an **idle agent no-ops** instead of replaying/re-engaging. | The result is already a durable file — the router never needs to re-fetch it from the agent. If the file is absent, the dispatch simply re-runs (reground keys on the file's presence). |
| 4 | Idle pings (`{"type":"idle_notification","idleReason":"available"}`) are **noisy and content-free**. | The router polls the scoped result path + its `<!-- orchestrate:complete -->` sentinel for completion, so idle pings are irrelevant to control flow. |

Net: a dispatched read-only agent (researcher/verifier) can complete and have its
result silently dropped by the channel — and orchestrate still recovers it, because
the result lives on disk, not in the notification. This is the read-channel twin of
the write-channel protection below.

## Worktree isolation lands on the main checkout (Claude Code)

The harness `isolation:worktree` can place an agent on the **primary checkout**
instead of an isolated worktree, and can cut a worktree from a **stale** default
branch (`origin/HEAD`) rather than your current branch. orchestrate compensates:

- A persona-independent floor (`guard-shared-checkout.sh`, ADR-0013) refuses
  working-tree/history-discarding git ops (`reset --hard`, `clean -f`,
  `checkout -f`/`.`/`--`, `switch --discard-changes`) against the primary checkout.
- The router creates worktrees via `runtime/worktree.sh`, cutting from the
  **current** branch (never `origin/HEAD`) and realigning `origin/HEAD` so the
  harness path benefits too.

Existing stale worktrees are not retroactively fixed; if you upgraded into the fix,
run `git remote set-head origin <your-canonical-branch>` and `git worktree prune`
once.

## Agent teams undermines isolation (Claude Code)

Claude Code's experimental **agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
off by default) turns dispatched subagents into peer-messaging *teammates* with a shared
task list and `SendMessage`. That is the opposite of orchestrate's model — isolated
dispatch-and-return personas whose only channel is disk, and control-state that lives only
in the board (ADR-0012). Under agent teams a persona can message peers and relay a control
signal (a "halt", a "commit now") the router must never take secondhand.

Unlike the other rows here, orchestrate **cannot compensate**: there is no per-dispatch
opt-out to force isolated subagents (verified 2026-07-06). The only lever is detection — a
`SessionStart` hook (`warn-agent-teams.sh`) warns when the variable is set (ADR-0023).
**Recommendation:** disable agent teams in any repo where you run orchestrate (unset
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, or remove it from `.claude/settings.json`); with it
on, treat orchestrate's single-writer / no-peer-control / disk-only-control guarantees as
advisory, not enforced.

## Agent-definition `model:` frontmatter is ignored (Claude Code)

A plugin agent's compiled `model:` (and the documented resolution order) does not bind:
subagents silently inherit the parent session's model unless the **caller passes `model`
on the dispatch call itself** (issues #44385 / #43869, confirmed bugs, no fix ETA as of
2026-07-14). Measured impact: a live run billed every persona at the parent flagship while
the definitions said haiku/sonnet/opus. `effort:` frontmatter appears to bind; only
`model:` is broken. orchestrate compensates: the router passes each persona's tier model +
effort **explicitly on every dispatch** (SKILL §2a′ table) and journals them on the
`dispatched` event, so `metrics model_mix` makes any drift visible. If the bug is fixed
upstream, the explicit param remains correct (it takes precedence by design).

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

## Writer records are per persona, not per ticket (all harnesses)

The hooks learn a writer's ticket, branch and prod targets from an on-disk record
the router writes before dispatch (ADR-0006). Since 0.8.29 there is one record per
persona (`active-writer.implementer.json`, `active-writer.actuator.json`,
ADR-0039), so a builder lane can no longer blank or retarget the actuator's
pre-apply gate, and an actuator with no record is denied rather than run ungated.
What remains:

| # | Behavior | What to do about it |
|---|---|---|
| 1 | Two **registered builders** share one implementer record; the second `set` overwrites the first's assigned branch and the first's next commit is refused. | Run registered builders one at a time (SKILL §9b). Per-ticket records are the next step if parallel builders earn it. |
| 2 | The gate covers **Actuator subagents only**. An apply the router runs inline in its own shell never passes it. | Dispatch an Actuator for prod applies, or accept that the operator go-ahead and CI are the only controls and say so in the ticket. |
| 3 | The records live in the repo's run dir, so **two sessions in one repo share them**; one session's `writer-ctx clear` removes the other's context, and reground HALTs on the other session's open writer. | One `/orchestrate` session per repo (DESIGN.md). Before `clear`, read the record and confirm it is yours. |
| 4 | On Codex and OpenCode the launchers pass no `TICKET`/`PROD_TARGETS` env, so the actuator gate relies on the same on-disk record there. With the fail-closed gate, an Actuator dispatched without `writer-ctx set` is denied on every command. | Register the Actuator before dispatch on every harness; a denied-everything Actuator means the registration step was skipped. |

## Credential confinement is advisory (all harnesses)

The actuator's credential scoping is **advisory** (ADR-0002): orchestrate cannot
enforce "no credentials for an unleased target" from inside the harness. The
guaranteed layer is lease **serialization** (single-writer per target). Scope the
actuator lane's creds to its leased targets in your deployment.

## Testing the plugin live (gotchas for the next tester)

Learned running 4 parallel real-world scenarios (headless `claude -p --plugin-dir`,
sonnet, isolated scratch repos) on 2026-07-02. None of these are orchestrate bugs,
but all three will confuse you if you don't know them going in:

| # | Behavior | What to do about it |
|---|----------|---------------------|
| 1 | **Task-list leakage into the parent session (CC).** Driving `claude -p` scenario sessions from *inside* a Claude Code session leaks the children's task items (TaskCreate) into the parent's task list via inherited session env — you'll see phantom "Implementer: …" / "Verifier: …" tasks that belong to dead child sessions and never complete. | Cosmetic; ignore or run the fleet from a plain shell. Don't chase the "stuck" tasks — their sessions are gone. |
| 2 | **A shared `--plugin-dir` is shared *mutable* enforcement.** Agents under test can edit the plugin's own hook scripts. Observed live: a router patched `keep-on-branch.sh` mid-run to unblock a (real) false-deny — with parallel scenarios sharing the dir, the patch leaked across scenarios *and into the plugin repo's working tree*, contaminating both the experiment and the checkout. | Give each scenario its **own copy** of the plugin dir, and `git diff` the real plugin dir after any live run. (The self-disarm hole itself is tracked in TODO.md as a hardening item.) |
| 3 | **Managed/remote environments carry OAuth in env, not in `~/.claude/.credentials.json`.** `claude -p` works fine, but any auth gate that only checks the credentials file (as `have_live_auth` did) makes live tiers self-skip while a hand-run probe succeeds — a confusing split. | Fixed in `tests/integration/lib.sh` (`have_live_auth` now also accepts `CLAUDE_CODE_OAUTH_TOKEN*` env). If you write new live gates, probe capability, not one credential shape. |

Also useful to know: a live fleet like this is the layer that catches what unit
tests structurally can't — the `keep-on-branch.sh` false-deny (hook cwd ≠ subagent
cwd under CC) shipped green through 292 unit assertions and fell over in the first
20 minutes of live dispatch. Budget a live pass before calling hook changes done.

## Codex-specific (codex-cli 0.142.1)

A live probe (`codex exec` headless) confirmed Codex's PreToolUse hooks **block for
the MAIN agent's hooked tools** (exit 2 + stderr contract, Claude-Code-shaped wire).
They do **not** reach a spawned subagent's tool calls, nor the `apply_patch` tool, so
the enforcement story was **scoped, not full parity** (ADR-0016). As of 0.8.0 (ADR-0017)
orchestrate dispatches each confined persona on Codex as its own top-level `codex exec --cd
<lane>`, so its writes are **OS-confined to its result subtree** (stronger than the CC
hook) rather than relying on the inert per-role `sandbox_mode`. The runtime hooks need no
per-harness fork; the items below are Codex behaviors orchestrate now compensates for, not
orchestrate bugs.

| # | Codex behavior | Status / how orchestrate compensates |
|---|----------------|--------------------------------------|
| 1 | A Writer could read the held-out oracle by shelling out (`cat`/`sed`) around the Read-tool path. | **Resolved in 0.6.1.** `deny-heldout-read.sh` now inspects `tool_input.command`, so the shell path is denied too. Harness-neutral. Note (per #6): on Codex this only covers the main agent; a spawned persona's shell reads are bounded by `sandbox_mode`, not this hook. |
| 2 | A wired hook silently **NO-OPS (fails OPEN)** unless its sha256 is trusted in `[hooks.state]` (or `--dangerously-bypass-hook-trust` is passed). | **Resolved (auto-seeded + self-verified).** The installer now **seeds** `[hooks.state]` so the floor is live on first run — no manual TUI approval. The `trusted_hash` is **never guessed**: the installer asks codex for the value codex itself computes (`codex app-server` → `hooks/list` → `currentHash`, which is deterministic and stable), keyed as `<hooks.json path>:<snake_case_event>:<group_idx>:<hook_idx>` (e.g. `…/hooks.json:pre_tool_use:0:0`). Because a **wrong** hash would fail open silently, the installer then **self-verifies**: it runs a deny probe under `codex exec` with **no** `--dangerously-bypass-hook-trust` and confirms the hook fires. If the probe does **not** fire (a codex version/format **drift** in the key or hash recipe), the installer **strips the seeds** and **loudly** falls back to documenting the two manual paths (TUI approve, or `--dangerously-bypass-hook-trust` for vetted CI) — it never leaves the operator believing the floor is live when it isn't. If codex/auth is unavailable at install time, the oracle + self-verify can't run, so the installer is honest about that (`docs-only`) and prints the manual paths. (ADR-0016.) |
| 3 | `effort: max` has **no Codex equivalent** (Codex tops out at `xhigh`). | **Live limitation.** The Verifier's max-effort adversarial lane runs at `xhigh` on Codex. Documented, not blocking. |
| 4 | Actuator credential confinement is **advisory** (ADR-0002), as on every harness. | Unchanged. Lease serialization is the only guaranteed layer; scope the actuator lane's creds in your deployment. |
| 5 | `sandbox_mode` is coarse (`workspace-write`); `writable_roots` is **additive** (adds writable dirs, never subtracts source) and is ignored in `read-only` mode. | **Compensated (0.8.0).** `writable_roots` cannot narrow a persona to its lane — so instead each persona is dispatched as its own `codex exec --cd <result-dir>` (ADR-0017), whose cwd subtree IS the OS-level writable boundary. For the main agent, `write-scope.sh` adds finer lane checks on top. |
| 6 | **PreToolUse does not fire inside a spawned subagent**, and `spawn_agent` shares the session sandbox (no per-agent knob). | **Resolved (0.8.0) via ADR-0017.** orchestrate no longer dispatches confined personas through `spawn_agent` on Codex; it runs each as its own top-level `codex exec --cd <result-dir>` (`dispatch-persona.sh`), so the OS sandbox confines its writes to its lane (source/prod refused at the syscall, sub-spawn-proof) AND the main-agent hook floor fires — OS-enforced, stronger than the CC hook. Requires the router's `network_access = true` (installer-set) so the nested persona session can reach the model. Validated live (out-of-lane write → `read-only file system`). The earlier claim that per-role `sandbox_mode` confines a spawn was wrong (corrected by live probe); this replaces that mechanism. |
| 7 | **`apply_patch` writes.** Codex top-level writes surface as the `apply_patch` tool; the old matcher `^(Read|Edit|Write|Bash)$` missed it entirely. | **Resolved (0.7.1), main-agent floor.** The installer wires `^(Read|Edit|Write|Bash|apply_patch)$` (routed), and `write-scope.sh` parses the patch body (`*** Add/Update/Delete File:`, `*** Move to:`) to confine every target — ANY out-of-scope target denies the whole patch (fail-closed). The same change made `write-scope` **tool-aware**, so the shared Codex matcher no longer makes it deny a confined persona's reads/test-runs. Verified live end-to-end: an out-of-scope `apply_patch` write is blocked with trust seeded, no bypass flag (`tests/integration/test_codex_apply_patch_route.sh`). Caveat (per #6): this is the **main-agent** floor; a spawned persona's `apply_patch` is still unhooked. |
| 8 | **SubagentStart does not fire in `codex exec` headless.** | **Live limitation.** Per-subagent model override via the `on-writer-dispatch` SubagentStart hook is **inert** headlessly. The role `.toml` `model` field sets the tier instead (verified working), so the `.toml` schema fix is the actual carrier of per-persona tiers. |

See `docs/notes/codex-support.md` for the verdict, the enforcement scope, and the
installer fixes still required.
