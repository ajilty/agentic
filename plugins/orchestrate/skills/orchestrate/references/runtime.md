# Judgment memory and hooks

## Judgment memory

Cross-goal decisions live in tracked `docs/adr/` with a derived `INDEX.md`,
kept by `adr.sh` (`next`, `add`, `supersede`, `reindex`); the planner treats an
`active` one as `TRUSTED`. When a fork resolves, run `ledger.sh decision
<ticket> <fork_id> [adr] [note]`; propose an ADR (`adr.sh add`) only for a
hard-to-reverse, surprising, real trade-off, and the operator decides. A goal
contradicting an `active` ADR raises a fork that ends in `adr.sh supersede`.

## Hooks

- **Shared-checkout floor** (every Bash command, every agent, you too): stops
  the canonical spellings of `reset --hard`, `clean -f`, `checkout -f`/`.`/`--`,
  and `switch -f`/`--discard-changes` when they would run in the primary
  checkout (by cwd, `cd`, `pushd`, or `git -C`, quotes honoured), refuses one
  whose checkout it cannot resolve, and journals `denied`. It is a floor, not
  a list of what is safe: `restore`, `stash drop`, `branch -D`, `worktree
  remove --force`, and commands run through `sh -c` or `--git-dir` discard work
  too, and every linked worktree is left alone. Do that work in a worktree.
- **Progress-page check**: a publish of the progress page that contradicts
  the board or itself is refused, each failure named. Rebuild it from the
  journal (`status-page-rules.md`); do not publish a copy from another path.
- **After a compaction** two hooks put back your core instructions and the
  regrounded board, which is authoritative. References are not put back.
  After an interruption the operator re-runs `/orchestrate:init`.
