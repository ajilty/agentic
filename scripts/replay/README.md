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
- `REPLAY_KEEP`: other paths in the repo to copy out before the sandbox is
  deleted.

Scoring is a script of the plugin's own that reads an output directory and
prints a line. There is no shared scoring format, on purpose: what counts as
the right behavior differs per plugin. `plugins/orchestrate/tests/eval/replay.sh`
is the worked example: a wrapper of settings plus two scorecards.

## What keeps a replay safe

On Linux each session runs inside a bubblewrap sandbox:

- **Files:** read-only everywhere. Your home directory, the temporary
  directories, `/run`, the source repo, the set and the output directory are
  replaced by empty ones. It can write only its snapshot, a throwaway home and
  a log directory.
- **Processes and environment:** its own process table, and an environment
  built from nothing.
- **Network:** with `pasta` installed, a network of its own, so services bound
  to this machine's loopback address are out of reach. Without it the runner
  warns and the session shares the machine's network. Either way, services
  bound to another address of this machine (a container bridge, a VPN address)
  and the name resolver's socket stay reachable.
- **Time:** the time limit runs inside the sandbox, so nothing a session
  started outlives it.
- **Results:** the runner copies them out itself: regular files only, never
  following a link the session left behind. Your scorer reads those copies,
  not the sandbox.

What the sandbox does not cover: the internet stays reachable, because the
model is reached over it, and the session holds the model login. `guard.py`
refuses the web, connected services, dispatches and any tool it does not know.
It is best effort, not the boundary: a session that got past it could send what
it can read (the snapshot, the plugin, your `CLAUDE.md`) out. It also refuses
some harmless commands (any `terraform` or `kubectl`, reads under `/etc`),
which a replay of work past its opening stage would feel.

Without a usable bubblewrap (macOS, some containers) there is no boundary: the
session runs as you. The runner refuses to start unless `REPLAY_UNCONFINED=1`.

`test.sh` pins what the guard promises and, with a stand-in for the CLI that
tries to get out, that the sandbox holds.
