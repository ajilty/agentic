# Verifier run-scope is a best-effort mutation denylist, not an allowlist

`agents.yaml` declares the Verifier as `run: tests-only`, and the capability
vocabulary says that tier "needs a run-scope hook." The threat is concrete: the
Verifier runs the held-out suite to judge a change, so a Verifier that can mutate
the working tree could **game the oracle** — edit the tests or the source so the
suite passes — defeating the whole point of fresh-context adversarial review.
Capability subtraction already denies the Verifier `Write`/`Edit`, but it keeps
`Bash` (it must run tests), and a shell can mutate files (`echo > test`,
`sed -i`, `git checkout`, `rm`). Something has to close that Bash-shaped hole.

The design question is *how* to scope `Bash` to "tests-only." Two shapes:

**Decision:** a best-effort, threat-model **DENYLIST** that blocks working-tree
and git-state mutation (git write subcommands — including behind `-C`/`-c`
options — `rm`/`mv`/`truncate`/`dd`/`tee`, `sed -i`/`perl -i`, and output
redirection to a real file), while allowing test execution and read-only
inspection. It is **defense-in-depth behind capability subtraction**, not a hard
guarantee: a determined escape (a `python -c`/`node -e` one-liner that opens a
file for write, `cp`, `install`) is **accepted residual** — the same advisory
posture as actuator credential confinement (ADR-0002). `agents.yaml` records this
honestly as `run_scope: { fail_closed: false }`.

## Considered options

- **Strict allowlist of test commands** (only `pytest`/`npm test`/`go test`/…
  may run) — the truly fail-closed shape. Rejected: robustly scoping a shell to
  "only tests" is repo-specific and brittle. Test runners vary per repo, and the
  common ones (`bash tests/run.sh`, `make test`) are arbitrary-execution escape
  hatches anyway, so the allowlist buys little while false-denying legitimate
  diagnostics (`grep`, `cat`, `git diff`) the Verifier needs. It would have to be
  configured per repo to be usable — friction with no proportionate safety gain.
- **No enforcement** (the status quo this ADR closes) — leaves `tests-only`
  hollow; the Verifier gets unrestricted `Bash` and the oracle is gameable.
  Rejected.
- **Threat-model denylist** (chosen) — targets exactly the gaming vector
  (mutation) on top of the no-`Write`/`Edit` floor; zero per-repo configuration;
  no false-denial of read-only inspection or test runs.

## Consequences

- The Verifier's primary confinement remains capability subtraction (no
  `Write`/`Edit`); `run-scope.sh` is the second layer that catches Bash-borne
  mutation. Neither alone is complete; together they cover the realistic vectors.
- Accepted residual escapes (language one-liners, `cp`, obscure paths) are
  documented in the hook body and `agents.yaml`, and `fail_closed: false` makes
  the best-effort posture explicit rather than presenting an unenforced
  constraint as a guarantee (per the enforcement appendix's own rule).
- The denylist must catch git mutation even behind intervening options
  (`git -C <dir> reset --hard`), so it matches the mutating subcommand as a word
  after `git`, not the contiguous `git <subcmd>` string. Read-only subcommands
  (`status`, `diff`, `log`, `show`) stay allowed.
- Like the other capability-scope hooks, `run_scope` is declared in `agents.yaml`
  and materialized per harness by the generators; the contract-parity test
  (`tests/test_build.sh`) fails the build if it is ever declared-but-unwired.

## Status

active

_Status: superseded by 0040_
