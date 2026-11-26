# Litmus: real-delivery comparison

Tells you whether an edit to a `CLAUDE.md` or rules file made agents behave
better, worse or no different. It asks each test case as its own session
against the old wording and the new wording, with the file placed where Claude
Code really loads it, and reports `pass`, `regress` or `inconclusive`.

Claude Code only. Plugins and skills are tested with the built-in
`claude plugin eval`; this covers the files it never loads.

## Run it

```sh
python3 scripts/litmus/litmus.py compare \
  --old OLD.md --new NEW.md --cases <cases-dir> --model haiku
```

- Cases are chosen by section. Each case names the headings of the file it
  exercises (`sections`), and only the cases for headings the edit touches are
  run; `--all` runs every case. Either way, when the edit touches a heading
  that no case in the run names, the run says which and cannot return `pass`:
  with every case that ran passing, it returns `inconclusive`, because part of
  the edit was never asked about. A case left out with `--only` or `--exclude`
  covers nothing. A heading the edit removes or renames away needs no case;
  its new name does. The summary file lists the headings touched and those
  without a case, also when no case at all was selected (`inconclusive`, with
  nothing asked and nothing spent, and `reason` saying so). Such a run still
  has to be able to start: without the CLI, or while another run holds the
  state folder, it returns 3 like any other. Coverage is by heading: a case
  that names a heading is not proof that it exercises every sentence under it.
- `--without "<sentence>"` in place of `--new`: does that sentence earn its place.
- `--same` in place of `--new`: the file against itself.
- `--scope project|user|rules`: how the file is delivered (default `project`).
- `--draw <name>`: a fresh sample. Without it, a repeat of the same comparison
  is answered from the cache and costs nothing; it is the same result, not a
  second measurement.
- `--reuse-old`: when the old wording was already sampled (same draw, cases,
  model, effort and Claude Code version), let those answers stand and ask only
  the new wording, about half the cost. The two halves of such a pair were
  asked at different times, and the result says how many pairs that is. With
  `--same` it becomes the drift check: the stored answers against the same
  file asked now, which measures whether anything but the wording moved in
  between. A Claude Code update makes stored answers unusable, on purpose.
- `probe`: for each scope, that the candidate alone loads and reaches the
  model; that each deliberate break is caught; that a tool call is refused.
  Run it once per machine and after a Claude Code upgrade.

`litmus.py compare --help` lists the rest. Exit status: 0 pass, 1 regress,
2 inconclusive, 3 no verdict (a broken run, the spend ceiling, an outage, an
interrupt, a bad command line).

The login is `CLAUDE_CODE_OAUTH_TOKEN` in the caller's environment (a token
from `claude setup-token`). It is passed to each session by name and never
written to disk. Every ledger row and run summary carries token counts (fresh
input, output, cache write, cache read) beside the list-price dollars.

## What a verdict means

Old and new answer the same question in pairs. A case stops as soon as it is
decided:

| State | Meaning |
| --- | --- |
| `worse` | new fails where old passed, beyond chance |
| `better` | the reverse |
| `holds` | new is shown not to be worse than old by more than the margin (15 points) |
| `undecided` | 30 pairs were not enough to say, or too many answers could not be graded |

`regress`: any case is worse. `pass`: every case is better or holds.
`inconclusive`: anything else.

On identical files, the chance that any case is flagged better or worse is at
most 5% per comparison. `judge.py` computes that exactly for its stopping rule
and the tests pin it. It assumes one session's answer does not depend on
another's; only same-file comparisons on real runs can show that.

### How often each verdict is reachable

With the default rules, `pass` needs every case to be close to deterministic.
Simulated, six cases:

| Each case passes this often under both wordings | A case ends `holds` | All six hold (`pass`) |
| --- | --- | --- |
| 100% | 100% | 100% |
| 99% | 86% | 40% |
| 95% | 55% | 3% |
| 90% | 33% | under 1% |
| 50% | 12% | never |

So a file compared with itself, or an edit that changes nothing, usually comes
back `inconclusive` unless its cases are near 0% or 100%. And a real drop is
not always caught: 100% to 10% is `worse` every time, 100% to 70% about 56% of
the time, 90% to 60% about 35%; the rest are `undecided`, never `pass`. A case
that sits in the middle under the old wording is a weak test, whatever tool
reads it.

## What keeps a run sound

- **Only the candidate loads.** Each session records every instruction file
  Claude Code loads. A session where the candidate is missing is retried once
  and then counted; three such sessions stop the run with no verdict. A session
  where any other instruction file loaded stops the run at once. Nothing from a
  run that stopped this way is kept in the cache.
- **Nothing rides along.** Each session has a throwaway home and an environment
  built from nothing, under `/var/tmp/litmus`. The run root may not sit under
  the home directory, `/tmp`, Claude Code's own scratch area, or anything that
  holds instruction files or a project above it.
- **No tools.** A hook refuses every tool call, records the attempt, and blocks
  the tool if the hook itself fails. An `@path` in a case is not expanded.
- **An outage is not a verdict.** Sessions that error or time out are counted;
  five stop the run with no verdict.
- **Spend is capped per model.** Every session's list-price cost goes into a
  ledger under `.agents/runs/litmus/`. A ledger that cannot be read refuses
  the run. A session that reports no cost (one killed for running too long,
  one that failed before it could say) is booked at `--session-budget`, which
  must be above zero and no more than the ceiling. `--ceiling-usd` is a wall
  for what sessions are allowed to spend: a session starts only if its budget
  still fits under the ceiling beside the budgets of the sessions already
  running. If it does not, it waits for one of them to end; when none is
  running, the run stops with no verdict. So a run stops once less than one
  `--session-budget` of room is left: set that budget near what a session
  really costs. Three limits: the CLI can itself pass its per-session limit
  by a little, and that little can pass the ceiling; if `litmus` is killed
  outright, the sessions then running are not booked; and the ledger is kept
  per model name as typed, so `opus` and `claude-opus-5-5` are counted apart.
- **One run at a time, at most three sessions.** A second invocation on the
  same state folder is refused.
- **An interrupt stops cleanly.** Sessions not yet started are dropped; the
  up to three in flight finish and are counted; no verdict is given. A second
  interrupt does not cut that wait short: those sessions are paid for, and
  each ends within its time limit. The table and the summary of a stopped run
  count every pair that was asked in full, up to the moment it stopped; a
  pair that was cut off by the stop is neither counted nor shown as void.

This is not an operating-system boundary: a session runs as you, with the
network up, and the tool-refusing hook is all that stands between it and your
files. Cases that need tools belong in the replay harness's sandbox.

Known limits:

- A file that Claude Code loads without telling the loading record (an
  `AGENTS.md` read directly, for one) cannot be seen by the load check, which
  is why such files above the run root refuse the run; and a record that
  arrives late can be missed in a short session, in either direction.
- A machine-wide instruction file refuses the run. Other machine-wide settings
  (a managed settings file with hooks or permissions of its own) are not
  looked for, and would apply to every session.
- The Claude Code version is read by running `claude --version` in your own
  environment, before any session's clean one exists.
- `compare` does not check that `probe` has passed for the installed Claude
  Code version. Run `probe` after an upgrade: it is what shows that loading
  and the tool refusal still work.
- A stored answer that cannot be read is asked again, with the other half of
  its pair (unless `--reuse-old` lets a stored old half stand).

## Replays: what a session does, not what it says

`compare` asks a model what it would do, with tools refused. `replay` checks
that against what a whole session does when it has tools:

```sh
python3 scripts/litmus/litmus.py replay \
  --old OLD.md --new NEW.md --cases <folder> --model claude-opus-5-5 --effort high
```

It needs a replay harness that can take a candidate file (`REPLAY_CANDIDATE`,
made-up project folders, a `facts.json` per run) and the sandbox runtime; it
refuses to start with a harness or a machine that lacks them. Point
`--harness` at another copy of `replay.sh` if the one in this checkout is older.

Each wording is handed to the repo's replay harness (`scripts/replay/`) as the
user-level file, on a made-up project per case, inside the harness's sandbox:
no network but the model's, nothing of yours readable. A replay case is a
folder with `ask.md` (the request as you would type it), `tree/` (the made-up
project), `expect` (`proceed` or `ask`) and `act` (one regular expression per
line). A run "acted" if a shell command it tried matches a line (a command the
sandbox refused still counts: the session chose to run it, and each run's
record says how many were refused, as `acts_refused`), or, for a line starting
with `path:`, if a file in the project whose path from the project's top
matches it differs after the session: `path:^CLAUDE\.md$` is the project's own
file, and a copy of that name anywhere else is not. "Differs" is the harness's
own finding once the session has ended: the file was changed, added, removed or
given another mode, by whatever route (a file tool, a redirection, an editor
run from the shell, a helper). A Write or Edit call by itself is not counted:
it can be let through and still fail. A link in `tree/` is another name for
the file it lands on, so with `CLAUDE.md` pointing at `AGENTS.md`, a change to
`AGENTS.md` matches `path:^CLAUDE\.md$`. For everything under a folder, write
the folder: `path:^\.claude/`.

It prints, per case, how often each wording acted and how often that was the
expected thing. It gives **no verdict**: a handful of replays is a
measurement. Exit 0 means every replay was measured, 3 that one was not (the
wording did not load or another file ran in its place, a file from outside the
project loaded, the session was not confined or left no result, it used tools
but none was recorded, the harness left no list of changed files or the
session rewrote the commit that list is measured from, or the harness left no
record), or that the run was stopped.

- **Spend.** The harness runs a whole batch, so the room for it is checked
  before anything starts: cases x runs x 2 wordings x `--session-budget`
  (default $2) plus a quarter of headroom, because the CLI's own per-session
  limit can be passed by a little, must fit under `--ceiling-usd` in the same
  ledger `compare` uses. Each wording's batch is booked in full before its
  first session and corrected when it ends, so a run that is interrupted or
  killed leaves the ledger saying too much, never too little. A replay that
  left no cost stays booked at its limit plus headroom.
- **Helpers.** By default the harness records and refuses every helper a
  session starts, which ends that session's turn. `--allow-agents` names the
  helper kinds that may really run, inside the same sandbox. Each run's record
  counts the helpers started and keeps the end of the closing message,
  unscored, for a person to read.
- **Nothing of yours is carried.** The harness is started with an empty
  throwaway home, a `PATH` of the folders its own tools live in, and the login
  token, so neither your login file nor your own preferences file can reach a
  session. It is never run without the sandbox runtime. A sandboxed session
  can read only the system's program folders (`/usr`, `/etc`, a Homebrew or
  Nix prefix), so the tools its side runs (`python3`, `git`, `timeout`,
  `bash`) must be found there. If one would be taken from anywhere else (a
  version manager's shim under your home, say), the run is refused before
  anything is spent.
- **The login.** A session holds the login token, as any session does, and
  with tools it can print its own environment into its transcript, which is
  kept. The harness cuts the token out of everything it keeps as its last
  step, and says per replay whether it had to; the run reports how many
  replays that was (`replays_with_login_in_kept_files` in the summary), and
  counts a replay whose check did not finish as not measured
  (`replays_login_unchecked`). After each
  batch `litmus` looks once more through every kept file and the harness's
  log (`login_removed_from_files`): a second look when the harness finished
  its own, the only one when it was stopped first or is an older harness. The
  harness finds the token as its exact text and also text shaped like a key;
  `litmus` finds the exact text only. Neither finds a copy in another
  encoding or in pieces. If `litmus` is killed outright
  mid-batch, its own look has not run and the harness's may not have: treat
  the run's output folder (under `.agents/runs/litmus/out/`) and any working
  folder left under the run root as holding the token, and delete them.
- **Stopping.** An interrupt, a closed terminal or the time limit stops the
  harness and everything it started. If `litmus` itself is killed outright,
  the harness is told to stop (Linux), and a working folder under the run root
  may be left behind.
- **Limits of the scoring.** A pattern is matched against the whole text of a
  shell command, so a command that only mentions the act (an `echo`, a commit
  message) counts as acting. A `path:` line does not see: a file the session
  changed and then put back; a file the project's own `.gitignore` leaves out;
  a new file whose name has a quote, a backslash, a control character or a
  non-ASCII letter (the harness drops it from its list; a file the project
  already had is seen). A session that rewrites the project's first commit
  (`git commit --amend` on it, `git rebase --root`) empties the harness's
  list: a run with such a command is reported as not measured unless a watched
  file was seen changed anyway. A session
  that must look something up remotely before it acts is stopped by the
  sandbox first, so its act may never be attempted: read the closing message. A
  session that acted and then ended in an error is not measured. Each run's
  record keeps the matching commands, so with a handful of replays, read them.
  "Acted" comes from the session's own tool record, which catches a session
  that tried, not one that lies.
- **Limits of the sandbox.** There is no network, so a session that looks
  something up remotely is refused and may stall; a case's `tree/` has to hold
  what a lookup would return.

## Pieces

- `engine.py` runs one session and reports facts. No grading, no verdict.
- `judge.py` turns paired outcomes into a verdict. Runs no sessions.
- `litmus.py` reads cases, grades answers, keeps the cache and ledger, prints the table.
- `test.sh` runs all of it against a stand-in for the CLI: no model, no spend.

Cases are folders holding `case.toml` (format in `litmus.py --help`). They are
never written by the author of the edit under test.
