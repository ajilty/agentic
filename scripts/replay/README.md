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

## Test a preferences file instead of a plugin

Set `REPLAY_CANDIDATE=<file>` to replay asks under a candidate version of your
user-level `CLAUDE.md`. The file takes the place of your own in the throwaway
home, so the two never run together, and it is covered by the same load check:
a run where it did not load is `noload`. A file that is missing, empty or
only whitespace is refused before any session starts. With a candidate set, `REPLAY_PLUGIN_DIR` is
optional: leave it out and no plugin is loaded.

Only the user-level file can be swapped. A candidate for a repo's own
`CLAUDE.md` is left out on purpose: current CLIs also read a repo's `AGENTS.md`
and `.claude/CLAUDE.md`, so the original could load beside the candidate and
the run would measure both.

To compare two versions, run the same set once per version into two output
directories and score each.

## Cases that are not a commit

A case may carry a `tree/` folder in place of a `commit` file: a made-up
situation, written for the test, that is no commit of any repo. The folder
becomes the project, copied as it stands: files, folders, and links as links,
never followed. A link must be relative and stay inside the folder (a
`CLAUDE.md` that points at `AGENTS.md`). Anything that is not a file, a folder
or a link is left out, and project-level harness config is dropped as for a
commit. An empty folder is a blank project. Commit cases are not checked this
way: a commit's own links arrive as they are.
When every case in a set brings its own folder, pass `-` as the source repo.

Such a case is refused by name when it cannot be used: a `.git` anywhere
inside, a `tree` that is itself a link, a link inside that is absolute or
leads out of the folder, a `commit` beside it, something in it that cannot be
read, or a `commit` case with no source repo to look in. A refusal removes any
older output for that case and the runner exits 3, so a result from an earlier
call is never read as this one's. This is stricter than for a commit case,
which is only named on stderr and skipped, with exit 0, as before: a caller
that scripts on the exit code will see the difference.

## facts.json

Each run that reached a session leaves a `facts.json` for a program to read. It
holds what the runner knows and no verdict:

| Key | Meaning |
| --- | --- |
| `case`, `run` | the case and which of its K runs |
| `model_asked`, `effort`, `models_used` | what was asked for, and the models that answered |
| `source` | `commit` or `tree` |
| `candidate_sha256` | the candidate's SHA-256, or null when the caller's own file was carried |
| `plugin`, `confined`, `postcompact` | whether a plugin was passed, the sandbox was up, the run was a post-compaction one |
| `expected`, `loaded`, `noload` | instruction files the load check required, the ones the load hook recorded (named by where they sat: `home/...`, `repo/...`), and whether one was missing |
| `is_error`, `cost_usd`, `turns`, `seconds` | from the session's result; null where it gave none |
| `refused`, `changed_files` | tool calls the guard refused, project files changed |
| `login_in_kept_files` | true when the last step changed what was kept: it cut the model login, or text shaped like one, out of a file, or removed a file or folder (named after the login, not a regular file, or not readable or rewritable); false when it changed nothing; null when that step did not finish |

A run stopped before its session (the sandbox's shared path appeared, the
candidate could not be placed, the snapshot could not be made) has a folder
and a summary row but no `facts.json`. `noload` is the same mark as the summary's. `loaded` is the
hook's record only, so it can be empty on a run that passed the check through
its transcript. In post-compaction mode cost, turns, seconds and refused calls
are the first turn's, as in the summary; changed files cover the whole run.

The file is always strict JSON. A number the session reported that is not a
finite number is `null`. The two lists the session reports about itself,
`loaded` and `models_used`, are cut to a few short entries made of the
characters a path or a model name has, but they are still the session's words:
compare them, never act on them.

A case skipped for lacking `ask.md` or a usable `commit` is only named on
stderr, as before, and whatever an earlier call left for it stays. A caller
that needs every case measured should use a fresh output directory per call
and count the `facts.json` files.

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
- **Login:** a session needs the model login, and its own commands can read
  whichever login it was given: Claude Code's setting that strips credentials
  from what a session starts (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`) is left
  off, because with it every Bash call fails inside the sandbox runtime
  (tried on CLI 2.1.328 with runtime 0.0.82). So what matters is which login
  that is, and what a run keeps.
  - *With `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` set* (do this):
    that variable is the whole login and your credential file stays behind.
    Prefer a token from `claude setup-token`: it can only make model
    requests. The last step of every run then checks everything it kept and
    overwrites, in place and at the same length, the key or token (when it
    is 20 characters or longer) and anything shaped like an Anthropic key,
    example text in a replayed project included. A kept file or folder whose
    name holds one is removed, as is a kept file that is not a regular file
    or could not be read or rewritten. That last case is every kept file of
    a run when the output directory is on a filesystem that cannot map files
    into memory: the run then keeps nothing but the list. A read-only kept
    file that held the login is left writable by its owner.
  - *With neither set:* the session gets a copy of
    `~/.claude/.credentials.json`, which it can read and which can do more
    than ask a model. The runner says so when it starts. Of what that file
    holds, the last step cuts only text shaped like an Anthropic key: any
    other secret in it that a session wrote into a kept file stays there.
  - *Either way:* a run where the last step changed anything lists it in
    `login-removed.txt`, is marked `login-removed` in the summary, and has
    `login_in_kept_files` true in `facts.json`. A mark written before the
    session starts stands until that step finishes, so a run that was
    interrupted, or whose step failed, keeps a `login-removed.txt` that says
    it is unchecked: treat its files as holding the login. A call that runs
    to its end marks such a run `login-unchecked` and exits 3. Not caught: a
    login written in another encoding or in pieces. With `REPLAY_UNCONFINED=1`
    none of this is a guarantee: a session that outlives its time limit can
    write to the output afterwards.
- **Time:** the time limit runs inside the sandbox, so nothing a session
  started outlives it, and an interrupted runner kills its sandboxes.
- **Not limited:** the memory and disk a session can fill inside its sandbox.
- **Results:** the runner copies them out itself: regular files only, never
  following a link the session left behind. Your scorer reads those copies,
  not the sandbox.

What the sandbox does not cover: the session talks to the model, so what it
reads (the snapshot, the plugin, your `CLAUDE.md` or the candidate in its place) goes to the model provider
as in any session, and tools the provider runs on its side, such as web search,
are a way out. `guard.py` refuses those, connected services, dispatches and any
tool it does not know. It is best effort, not the boundary. It also refuses
some harmless commands (any `terraform` or `kubectl`, reads under `/etc`),
which a replay of work past its opening stage would feel. So would this: the
runtime refuses writes to `.git/config`, `.git/hooks`, `.mcp.json`, shell
startup files and a few more paths in the snapshot (its "mandatory deny paths"). That refusal is a side effect, not what keeps
git safe: once a session has run, the runner treats the snapshot's git setup as
the session's and runs git on it only inside the sandbox.

Another harmless command the guard refuses shows at the opening stage too: the
guard judges a whole command, the text it only stores included, so a session saving a note whose words name
`.claude/settings` (a work item that lists per-checkout files, say) is refused
as if it had touched its own settings. Measured on the first 28 real replays:
1 of 153 shell commands; the session carried on, and the refusal is in that
run's `guard.jsonl`. It is left as it is: two attempts to let stored text
through each let commands through that run it. Whether the sandbox already
makes that settings check unnecessary is an open question.

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
