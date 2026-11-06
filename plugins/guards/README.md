# guards

Hooks that guard against known failure modes. Each guard is one script, one job, and the plugin is the on/off switch for the set.

| Guard | Event | Posture | What it does |
|---|---|---|---|
| `validate-syntax.sh` | PostToolUse on `Write`/`Edit` | lint assist, fail-open | Parses the just-written `.json`/`.yaml`/`.yml` file (and the YAML frontmatter of `.md` files) with `jq`/`yq`; parse errors go back to Claude for same-turn self-correction |
| `lint-markdown.sh` | PostToolUse on `Write`/`Edit` | lint assist, fail-open | Runs `rumdl` check-only over the just-written `.md` file, but only if it is ship-bound (paths containing `/tmp/`, `/scratchpad/`, `/.cache/`, and auto-memory files under `/.claude/projects/*/memory/` are skipped); findings go back to Claude for same-turn self-correction |
| `guard-git-staging.sh` | PreToolUse on `Bash` | hard gate | Denies `git add -A`/`.`/`-u`/`*` (`git add -u -- <path>` is allowed) and `git commit -a` so unrelated dirty files cannot ride into a commit; Claude is told to stage explicit paths |

## How the feedback loop works

Both PostToolUse guards read the written file's path from the hook payload on stdin and check exactly that one file. On a problem they exit 2 with the tool's output on stderr, which Claude Code injects into the model's context as a blocking error, so Claude sees the exact finding and fixes it before moving on. A clean file is silent.

The PreToolUse guard reads the shell command from the payload, splits chains and pipelines into simple commands, and inspects each `git` invocation's subcommand and arguments (after global options such as `-C <dir>`). A sweeping form exits 2 with a one-line reason, which blocks the call and shows the reason to Claude.

## Why not `git diff`-based validation

Validating "changed files" via `git diff --name-only` misses new untracked files (the primary `Write` case), scans unrelated dirty files on every edit, and breaks when the session cwd is not the repo root. These hooks validate exactly the one file the tool just wrote, independent of git state.

## Markdown lint: scope, rules and config

Only ship-bound files are linted. A path containing `/tmp/`, `/scratchpad/`, or `/.cache/`, or matching `/.claude/projects/*/memory/`, exits 0 before rumdl runs: those files are never committed. Repo files are always linted.

The linter is [rumdl](https://github.com/rvben/rumdl), a fast single-binary Markdown linter with markdownlint-compatible rule ids (`MD001`..). It runs check-only; the guard never passes `--fix`, because auto-fixing prose is how a wrapped line becomes a heading.

Config resolution is rumdl's own, anchored at the linted file's directory:

1. Nearest `.rumdl.toml`, `rumdl.toml`, or markdownlint-style `.markdownlint.{yaml,yml,json,jsonc}` walking up to the repo's `.git` boundary. Projects you contribute to keep their conventions.
2. Otherwise `$XDG_CONFIG_HOME/rumdl/rumdl.toml` (`~/.config/rumdl/rumdl.toml`). Put your personal defaults here; a common starting point is disabling line length:

   ```toml
   [global]
   disable = ["MD013"]
   ```

3. Otherwise rumdl's built-in defaults (80-character lines, which will be noisy on prose).

`rumdl explain MD0xx` describes any rule. Findings are capped at 20 per write so one file cannot flood the context.

## Staging gate: exactly what is denied

After any git global options (`-C <dir>`, `-c k=v`, `--git-dir=`, `--work-tree=`):

- `git add` with `-A`, `--all`, `--[no-]ignore-removal`, short clusters containing `A` or `u` (`-Av`), or the pathspecs `.`, `./`, `..`, `../`, `*`, `:/`, `:(top)`, quoted or not. `-u`/`--update` is denied unless followed by `--` and at least one non-sweeping pathspec: `git add -u`, `git add -u .`, and `git add -u -- .` are denied, `git add -u -- src/a.py` is allowed.
- `git commit` with `-a`, `--all`, or short clusters containing `a` (`-am`, `-sam`).

Each simple command in a `&&`/`;`/`|`/newline chain is inspected, so `cd x && git add .` is caught. Quoted strings and heredoc bodies are opaque text, so a commit message that says `-a` or `git add -A` is allowed. Not denied: `git add -u -- <path>`, `git add -p <path>`, `git add -N <path>`, `git checkout -- .`, `git diff .`, `git stash -u`, and any non-git command (the `dotfiles` wrapper's `add -u` flow is unaffected). The matcher is `Bash` only; Windows PowerShell sessions are not inspected, and the parser assumes POSIX shell syntax.

## Behavior summary

| Case | Result |
|---|---|
| Valid JSON/YAML, clean Markdown | Silent pass (exit 0) |
| Invalid JSON/YAML, Markdown findings | Tool output fed back to Claude (exit 2) |
| rumdl present but fails (bad config) | Error fed back to Claude (exit 2); a silently dead guard is worse than a noisy one |
| Sweeping `git add`/`commit -a` | Call blocked with reason (exit 2) |
| Other extensions / other commands | Skipped |
| JSONC dialects (`tsconfig*.json`, `jsconfig*.json`, `.vscode/`, `devcontainer.json`) | Skipped, comments are legal there |
| `jq` not installed | All guards silent no-op (fail-open) |
| `yq` / `rumdl` not installed | That guard is a silent no-op |

## Dependencies

- `jq` (required by every guard to read the hook payload; without it the plugin is a no-op)
- `yq` (optional; YAML checks skipped without it. [mikefarah/yq](https://github.com/mikefarah/yq) v4 or python-yq)
- `rumdl` (optional; Markdown lint skipped without it. `brew install rumdl`, `uv tool install rumdl`, `pip install rumdl`)

## Install

```text
/plugin install guards@ajilty
```

Or in settings: `"enabledPlugins": { "guards@ajilty": true }`.

## Tests

`bash plugins/guards/tests/run.sh` drives every hook with fixture payloads on stdin. Markdown lint tests skip when `rumdl` is absent; frontmatter tests skip without yq v4.

## Known limitations

- Multi-document YAML is validated as `yq` accepts it (all documents parsed).
- JSON5 and other comment-tolerant files not on the skip list will false-positive; add patterns to the `case` skip arm in `hooks/validate-syntax.sh` if you hit one.
- The staging gate does not parse shell quoting or command substitution; a sweeping `git add` hidden inside `$(...)` or a heredoc executed later is not caught. It guards the common case, not an adversary.
- rumdl's rule set is markdownlint-compatible in ids and config format but not a published rule-for-rule match; findings can differ slightly from markdownlint-cli2.
