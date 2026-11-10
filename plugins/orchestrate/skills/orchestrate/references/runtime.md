# Judgment memory and hooks

Router reference (core: `../SKILL.md`). Where cross-goal decisions live and what the plugin's hooks do.

## Judgment memory

Cross-goal decisions live in tracked `docs/adr/` with a derived `INDEX.md`,
kept by `adr.sh` (`next`, `add`, `supersede`, `reindex`); the planner treats an
`active` one as `TRUSTED`. When a fork resolves, run `ledger.sh decision
<ticket> <fork_id> [adr] [note]`; propose an ADR (`adr.sh add`) only for a
hard-to-reverse, surprising, real trade-off, and the operator decides. A goal
contradicting an `active` ADR raises a fork that ends in `adr.sh supersede`.

## Hooks

Claude Code runs all four. OpenCode is wired to run the two compaction scripts, but their output does not reach you there. Codex runs none.

- **Shared-checkout floor** (every Bash command, every agent, you too): stops
  the canonical spellings of `reset --hard`, `clean -f`, `checkout -f`/`.`/`--`,
  and `switch -f`/`--discard-changes` when they would run in the primary
  checkout (by cwd, `cd`, `pushd`, or `git -C`, quotes honoured), refuses one
  whose checkout it cannot resolve, and journals `denied`. It is a floor, not
  a list of what is safe: `restore`, `stash drop`, `branch -D`, `worktree
  remove --force`, and commands run through `sh -c` or `--git-dir` discard work
  too, and every linked worktree is left alone. Do that work in a worktree.
- **Progress-page check** (every publish of `.agents/runs/orchestrate/status.html`):
  runs `ledger.sh page-check --publish` and refuses a page that contradicts
  the board or itself, naming each failure. Rebuild the page from the journal
  and publish again; do not publish a copy from another path.
- **Core re-attach** (after every compaction, in a repo with a board): prints
  your core instructions (`ledger.sh core`) back into context, because a
  compaction keeps at most the first part of a skill. References are not
  re-attached: read each again at its step.
- **Compaction recovery**: in a repo with a board, runs `ledger.sh reground`,
  and injects the board as authoritative.
  After an interruption the operator re-runs `/orchestrate:init`.
