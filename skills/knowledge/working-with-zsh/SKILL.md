---
name: working-with-zsh
description: "zsh as the command shell (the Bash tool on macOS, any script run under zsh). Load before the first Bash tool call in a session when the shell is zsh; covers words that start with = (separator lines, == tests) and unquoted variables that do not word-split. Also when porting a bash one-liner or script to zsh."
---

# Working with zsh — sharp edges

zsh is the login shell on macOS, so harness shell calls run there, not in bash. Bash habits
that break:

## A word starting with `=` aborts the whole call

- **An unquoted word beginning with `=` is `=command` expansion** (replaced by that command's
  path), so a separator line like `echo =====` looks up a command named `====` and fails
  `(eval):1: ==== not found`, exit 1. **Every later command in the same call is skipped**,
  later lines and `|| fallback` included: `zsh -c 'echo a; echo =====; echo b'` prints only
  `a`. Quote it (`echo '====='`) or use `---`; a mid-word `=` (`x=====y`) is safe.
  `[ "$a" == b ]` fails `= not found`: use `=` or `[[ ]]`.

## Unquoted variables do not word-split

- **`$VAR` holding several options passes them as ONE argument.**
  `P="--profile x --region y"; aws ... $P` fails `aws: [ERROR]: Unknown options: --profile x
  --region y`; in the bash loop `for p in "<repo> <num>"; do set -- $p; gh pr view $2 -R $1; done`
  `$1` gets the whole string and the empty `$2` is dropped, so every call dies with
  `argument required when using the --repo flag`.
  Split explicitly with `${=P}`, use an array (`P=(--profile x --region y); aws ... "${P[@]}"`),
  or set the tool's env var instead (`export AWS_PROFILE=x AWS_REGION=y`).

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
