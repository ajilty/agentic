#!/usr/bin/env bash
# PreToolUse (Bash): the git-safety floor (ADR-0013). Persona independent: no agent may run a
# working-tree or history DISCARDING git op (reset --hard, clean -f, checkout -f/./--, switch -f)
# against the PRIMARY checkout; a linked worktree is a throwaway sandbox and is left alone.
# Which checkout a statement hits is resolved per statement: `git -C DIR`, else the last
# `cd DIR` before it in the same command line, else the payload's cwd (ADR-0040), else $PWD.
# Contract (Claude Code): ALLOW = exit 0 with NO stdout; DENY = reason on stderr + exit 2.
set -uo pipefail
# ADR-0032: a denial is FEEDBACK. Journal it to the board (event "denied") on any exit-2
# path via the EXIT trap; never blocks, never alters the deny, never touches stdout.
_journal_denial(){ rc=$?; [ "$rc" = 2 ] || return 0
  c="${hit:-${cwd:-$PWD}}"; gcdj="$(git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
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
# A payload cwd that does not exist cannot be where the command runs: fall back to the
# process cwd instead of failing open.
[ -d "$cwd" ] || cwd="$PWD"

# Word-bounded normalization: collapse shell separators to spaces and wrap, so verb checks
# can't match substrings.
norm=" ${cmd//[;|&()\`]/ } "
case "$norm" in *" git "*) ;; *) exit 0 ;; esac   # not a git command -> not our concern

# Resolve a cd/-C target against a base dir: absolute stays, ~ expands, relative joins.
_resolve(){ local b="$1" t="$2"; t="${t#[\"\']}"; t="${t%[\"\']}"
  case "$t" in
    /*) printf '%s' "$t" ;;
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s/%s' "$HOME" "${t#\~/}" ;;
    *) printf '%s/%s' "$b" "$t" ;;
  esac; }
# Primary checkout test: in a linked worktree git-dir is .git/worktrees/<name> while
# git-common-dir is .git, so they differ. Not a repo, or a missing dir, is not primary.
_primary(){ local d="$1" gd gcd
  gd="$(git -C "$d" rev-parse --git-dir 2>/dev/null)" && [ -n "$gd" ] || return 1
  gcd="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ "$(cd "$d" && cd "$gd" 2>/dev/null && pwd -P)" = "$(cd "$d" && cd "$gcd" 2>/dev/null && pwd -P)" ]; }

# Check each STATEMENT's own args, not the whole compound line: a token in one statement (an
# unrelated path, a commit-message heredoc) must not trip a verb in another. Live 2026-07-06:
# `git checkout -b X && git commit ...` was false-denied by a `.` or `--` elsewhere in the line.
# The directory each statement runs in is tracked across the line: a `cd DIR` statement moves
# it (relative to the dir before it), a subshell's closing paren restores it, and `git -C DIR`
# overrides it for that statement. So `git -C <primary> reset --hard` and
# `cd <primary> && git reset --hard` from a worktree are judged against the primary.
here="$cwd"; stack=(); hit=""
while IFS= read -r seg; do
  case "$seg" in
    '(') stack+=("$here"); continue ;;
    ')') if [ "${#stack[@]}" -gt 0 ]; then here="${stack[${#stack[@]}-1]}"; unset 'stack[${#stack[@]}-1]'; fi; continue ;;
  esac
  read -ra tok <<< "$seg"; [ "${#tok[@]}" -gt 0 ] || continue
  if [ "${tok[0]}" = cd ]; then
    case "${tok[1]:-}" in ''|'~') here="$HOME" ;; -) ;; *) here="$(_resolve "$here" "${tok[1]}")" ;; esac
    continue
  fi
  n=" $seg "
  case "$n" in *" git "*) ;; *) continue ;; esac
  d=0
  case "$n" in *" reset "*)    case "$n" in *" --hard "*) d=1 ;; esac ;; esac
  case "$n" in *" clean "*)    case "$n" in *" -f"*)     d=1 ;; esac ;; esac   # -f / -fd / -ffdx
  case "$n" in *" checkout "*) case "$n" in *" -f "*|*" --force "*|*" . "*|*" -- "*) d=1 ;; esac ;; esac
  case "$n" in *" switch "*)   case "$n" in *" --discard-changes "*|*" -f "*) d=1 ;; esac ;; esac
  [ "$d" = 1 ] || continue
  # git's global options sit between `git` and the verb; each -C is relative to the last.
  eff="$here"; i=0
  while [ "$i" -lt "${#tok[@]}" ] && [ "${tok[$i]}" != git ]; do i=$((i+1)); done
  i=$((i+1))
  while [ "$i" -lt "${#tok[@]}" ]; do
    case "${tok[$i]}" in
      -C) i=$((i+1)); [ "$i" -lt "${#tok[@]}" ] && eff="$(_resolve "$eff" "${tok[$i]}")" ;;
      -c) i=$((i+1)) ;;
      -*) ;;
      *) break ;;
    esac
    i=$((i+1))
  done
  if _primary "$eff"; then hit="$eff"; break; fi
done <<< "$(printf '%s' "$cmd" | sed 's/(/\
(\
/g; s/)/\
)\
/g' | tr ';|&`' '\n')"
[ -n "$hit" ] || exit 0
echo "orchestrate: refusing a destructive git op on the SHARED main checkout ($hit; SKILL.md \"Hooks\", ADR-0013): operate in a worktree; recreate, don't reset" >&2
exit 2
