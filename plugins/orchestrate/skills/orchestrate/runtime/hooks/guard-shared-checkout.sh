#!/usr/bin/env bash
# PreToolUse (Bash): the git-safety floor (ADR-0013). Persona independent: no agent may run a
# working-tree or history DISCARDING git op (reset --hard, clean -f, checkout -f/./--, switch -f)
# against the PRIMARY checkout; a linked worktree is a throwaway sandbox and is left alone.
# The primary is resolved from the payload's cwd, not this process's cwd (ADR-0040).
# Contract (Claude Code): ALLOW = exit 0 with NO stdout; DENY = reason on stderr + exit 2.
set -uo pipefail
# ADR-0032: a denial is FEEDBACK. Journal it to the board (event "denied") on any exit-2
# path via the EXIT trap; never blocks, never alters the deny, never touches stdout.
_journal_denial(){ rc=$?; [ "$rc" = 2 ] || return 0
  c="${cwd:-$PWD}"; gcdj="$(git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  case "$gcdj" in */.git) bj="${gcdj%/.git}/.agents/runs/orchestrate/board.jsonl";; *) bj="$c/.agents/runs/orchestrate/board.jsonl";; esac
  [ -f "$bj" ] || return 0   # no board here -> skip
  rt="$(cd "$(dirname "$0")/.." && pwd)" || return 0
  n="$(printf '%.80s' "${cmd:-${p:-}}" | tr '\n' ' ' | tr '"\\' "'/")"
  ( cd "$c" 2>/dev/null; bash "$rt/ledger.sh" append "{\"event\":\"denied\",\"hook\":\"guard-shared-checkout\",\"persona\":\"${persona:--}\",\"note\":\"$n\"}" ) >/dev/null 2>&1 || true
  return 0; }
trap _journal_denial EXIT
in=""; [ -t 0 ] || in="$(cat 2>/dev/null || true)"
J(){ [ -n "$in" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }
cmd="$(J .tool_input.command)"; [ -n "$cmd" ] || cmd="${TOOL_INPUT:-${CODEX_TOOL_INPUT:-}}"
[ -n "$cmd" ] || exit 0
cwd="$(J .cwd)"; [ -n "$cwd" ] || cwd="$PWD"

# Word-bounded normalization: collapse shell separators to spaces and wrap, so verb checks
# can't match substrings and inter-token options (git -C <dir> reset) can't slip past.
norm=" ${cmd//[;|&()\`]/ } "
case "$norm" in *" git "*) ;; *) exit 0 ;; esac   # not a git command -> not our concern

# Check each STATEMENT's own args, not the whole compound line: a token in one statement (an
# unrelated path, a commit-message heredoc) must not trip a verb in another. Live 2026-07-06:
# `git checkout -b X && git commit ...` was false-denied by a `.` or `--` elsewhere in the line.
destructive=0
while IFS= read -r seg; do
  n=" $seg "
  case "$n" in *" git "*) ;; *) continue ;; esac
  case "$n" in *" reset "*)    case "$n" in *" --hard "*) destructive=1 ;; esac ;; esac
  case "$n" in *" clean "*)    case "$n" in *" -f"*)     destructive=1 ;; esac ;; esac   # -f / -fd / -ffdx
  case "$n" in *" checkout "*) case "$n" in *" -f "*|*" --force "*|*" . "*|*" -- "*) destructive=1 ;; esac ;; esac
  case "$n" in *" switch "*)   case "$n" in *" --discard-changes "*|*" -f "*) destructive=1 ;; esac ;; esac
done <<< "$(printf '%s' "$cmd" | tr ';|&()`' '\n')"
[ "$destructive" = 1 ] || exit 0

# Only block on the PRIMARY worktree. In a linked worktree, git-dir is .git/worktrees/<name>
# while git-common-dir is .git, so they differ and the op is allowed.
gd="$(git -C "$cwd" rev-parse --git-dir 2>/dev/null || true)"; [ -n "$gd" ] || exit 0
gcd="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)"
if [ "$(cd "$cwd" && cd "$gd" 2>/dev/null && pwd -P)" = "$(cd "$cwd" && cd "$gcd" 2>/dev/null && pwd -P)" ]; then
  echo "orchestrate: refusing a destructive git op on the SHARED main checkout (§9a): operate in a worktree; recreate, don't reset" >&2
  exit 2
fi
exit 0
