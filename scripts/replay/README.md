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
The frozen copy and the throwaway home go under `TMPDIR` (default `/tmp`); where
is your choice. Each run records which instruction files the session loaded
(`loaded.jsonl`). If the replayed repo's `CLAUDE.md` or yours did not load, the
run is marked `noload` in the summary and the runner exits 3: a session without
its instructions is not the run you asked for. The check covers `CLAUDE.md` in
the throwaway home, at the repo's root and in its `.claude/`. It does not cover
a repo that has only `AGENTS.md` (the load hook does not fire for it), rules
files, or whether a file loaded again after a compaction; `loaded.jsonl` records
that reload when it happens.
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

Each session runs inside Anthropic's
[sandbox runtime](https://github.com/anthropics/sandbox-runtime) (`srt`), the
boundary Claude Code's own sandbox is built on, with a policy the runner writes
per session. Install it once:

```bash
npm install -g @anthropic-ai/sandbox-runtime   # Linux also needs bubblewrap, socat and ripgrep
```

- **Files:** it can read the system's programs, the CLI, the plugin, this
  harness, and its own snapshot, throwaway home and log directory, and write
  only those last three. Your home directory, the temporary directories,
  `/run`, the source repo, the set and the output directory are not there.
  One exception is the runtime's own: on Linux it shares `/tmp/claude` with
  the machine while that path exists, so the runner refuses to start, or to
  start a further session, if it does.
- **Network:** none of its own. Every connection goes through the runtime's
  proxy, which passes only the model's hosts. This machine's services are out
  of reach.
- **Processes and environment:** its own process table, and an environment
  built from nothing.
- **Time:** the time limit runs inside the sandbox, so nothing a session
  started outlives it, and an interrupted runner kills its sandboxes.
- **Not limited:** the memory and disk a session can fill inside its sandbox.
- **Results:** the runner copies them out itself: regular files only, never
  following a link the session left behind. Your scorer reads those copies,
  not the sandbox.

What the sandbox does not cover: the session talks to the model, so what it
reads (the snapshot, the plugin, your `CLAUDE.md`) goes to the model provider
as in any session, and tools the provider runs on its side, such as web search,
are a way out. `guard.py` refuses those, connected services, dispatches and any
tool it does not know. It is best effort, not the boundary. It also refuses
some harmless commands (any `terraform` or `kubectl`, reads under `/etc`),
which a replay of work past its opening stage would feel. So would this: the
runtime refuses writes to `.git/config`, `.git/hooks`, `.mcp.json`, shell
startup files and a few more paths in the snapshot (its "mandatory deny paths"). That refusal is a side effect, not what keeps
git safe: once a session has run, the runner treats the snapshot's git setup as
the session's and runs git on it only inside the sandbox.

On Ubuntu 24.04 and later the runtime also needs AppArmor out of its way:
`sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` and
`sudo apparmor_parser -R /etc/apparmor.d/bwrap-userns-restrict` (both last
until reboot; the CI job does the same). If the runtime cannot start, the
runner prints the runtime's own error.

The runtime is a beta. This harness is tested with 0.0.82 on Linux. macOS is
untested and may not work: the policy's readable paths are Linux's, and there
the runtime shares `/private/tmp/claude` whether or not it exists. Without a usable runtime
there is no boundary: the session runs as you. The runner refuses to start
unless `REPLAY_UNCONFINED=1`.

`test.sh` pins what the guard promises and, with a stand-in for the CLI that
tries to get out, that the sandbox holds.
