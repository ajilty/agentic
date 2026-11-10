# Replay harness

Replays past asks through a plugin, on a frozen copy of the repo each ask was
made against, and keeps what the session did. Use it to measure an instruction
change before and after on real asks: did the session load its instructions,
ask before acting, still follow them after a compaction.

Claude Code only. The built-in `claude plugin eval` covers conventional plugin
evals and is the first thing to reach for; this harness exists for what its
docs do not offer: a forced compaction inside one process, a log of every
refused tool call per turn, and scoring by your own script.

## Run it

```sh
REPLAY_PLUGIN_DIR=plugins/<name> REPLAY_PREFIX='/<name>:<command> ' \
  bash scripts/replay/replay.sh <set-dir> <source-repo> <out-dir>
```

`replay.sh`'s header lists the case format, every setting and every output file.
Cases are real asks and name real systems: keep the set outside this repo.

## Plug a plugin in

A plugin supplies three things, all optional, and scores the output itself:

- `REPLAY_PREFIX`: how a run starts, usually the plugin's slash command.
- `REPLAY_JOURNAL`: an append-only log the plugin writes in the repo, if it has
  one. Its new rows are kept per turn.
- `REPLAY_COLLECT`: a command that copies anything else out of the sandbox
  before it is deleted.

Scoring is a script of the plugin's own that reads an output directory and
prints a line. There is no shared scoring format, on purpose: what counts as
the right behavior differs per plugin. `plugins/orchestrate/tests/eval/replay.sh`
is the worked example: a wrapper of settings plus two scorecards.

## What keeps a replay safe

The session has nothing to misuse: a `git archive` snapshot with no remote, a
throwaway home directory, and an environment with no inherited credentials.
`guard.py` adds a best-effort refusal of dispatches, connected services, the
web, and recognised network, cloud and outside-path commands. The guard is not
the boundary. `test.sh` pins what the guard promises.
