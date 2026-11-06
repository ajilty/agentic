#!/usr/bin/env bash
# PreToolUse (Bash): the git-safety floor (ADR-0013). Persona independent.
#
# Stops a git command that discards work when it would run in the PRIMARY checkout
# (git-dir == git-common-dir): `reset --hard`; `clean` with `--force` or an `f` in a short
# flag cluster (-f, -fd, -df, -xdf); `checkout` with `--force`, an `f` in a short cluster
# (-f, -qf), `.`, or `--`; `switch` with `--force`, `--discard-changes`, or an `f` in a
# short cluster. Redirects glued to a word (`--hard>/dev/null`) are split off.
#
# The command is split into shell words (single and double quotes honoured, so a quoted
# directory with spaces is one word) and statements (; & | newline, subshell parens).
# Comments and heredoc bodies are skipped. The directory each statement runs in is tracked
# across the line: `cd [-L|-P|--] DIR`, `cd -`, `pushd DIR`, and `popd` move it, a
# subshell's closing paren restores it, and `git -C DIR` overrides it for one statement;
# it starts at the payload's cwd (ADR-0040), else $PWD. When a destructive verb is present
# and that directory cannot be resolved (a variable, command substitution, glob, a target
# that does not exist so the cd may fail, or `cd -`/`popd` with nothing before it), the
# command is DENIED with that reason. jq is required for allow decisions: without it the
# payload cannot be parsed, so any destructive verb in the raw input is DENIED.
#
# Out of scope (allowed here; the briefs, not this hook, cover them): `--git-dir`/
# `--work-tree` options and `GIT_DIR=`/`GIT_WORK_TREE=` environment; commands run through
# `sh -c`, `bash -c`, `eval`, `xargs`, or inside a command substitution; other discarding
# verbs (`restore`, `stash drop`, `branch -D`, `worktree remove --force`, `read-tree`,
# `checkout-index`); shell tools other than Bash; and an operator checkout that is itself
# a linked worktree, since every linked worktree is left alone.
#
# Contract (Claude Code): ALLOW = exit 0 with NO stdout; DENY = reason on stderr + exit 2.
# Runs under bash 3.2 (macOS /bin/bash).
set -uo pipefail
# ADR-0032: a denial is FEEDBACK. Journal it to the board (event "denied") on any exit-2
# path via the EXIT trap; never blocks, never alters the deny, never touches stdout.
_journal_denial(){ rc=$?; [ "$rc" = 2 ] || return 0
  c="${hit:-${cwd:-$PWD}}"; gcdj="$(git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  case "$gcdj" in */.git) bj="${gcdj%/.git}/.agents/runs/orchestrate/board.jsonl";; *) bj="$c/.agents/runs/orchestrate/board.jsonl";; esac
  [ -f "$bj" ] || return 0   # no board here -> skip
  rt="$(cd "$(dirname "$0")/.." && pwd)" || return 0
  n="$(printf '%.80s' "${cmd:-${in:-}}" | tr '\n' ' ' | tr '"\\' "'/")"
  ( cd "$c" 2>/dev/null; bash "$rt/ledger.sh" append "{\"event\":\"denied\",\"hook\":\"guard-shared-checkout\",\"persona\":\"${persona:--}\",\"note\":\"$n\"}" ) >/dev/null 2>&1 || true
  return 0; }
trap _journal_denial EXIT
in=""; [ -t 0 ] || in="$(cat 2>/dev/null || true)"
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
J(){ [ -n "$in" ] && [ "$have_jq" = 1 ] && printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }

# No jq: the payload cannot be parsed into a command and a cwd. Fail closed on any
# destructive verb anywhere in the raw input; allow everything else.
if [ -n "$in" ] && [ "$have_jq" = 0 ]; then
  re='git.*(reset.*--hard|clean.*([[:space:]]-[a-zA-Z]*f|--force)|checkout.*([[:space:]]-[a-zA-Z]*f|--force|[[:space:]]\.|[[:space:]]--([[:space:]]|"|\\))|switch.*([[:space:]]-[a-zA-Z]*f|--force|--discard-changes))'
  if printf '%s' "$in" | grep -Eq "$re"; then
    echo "orchestrate: jq is not installed, so the shared-checkout floor cannot tell which checkout this command runs in and refuses any destructive git verb (reset --hard, clean -f, checkout -f/./--, switch -f). Install jq, or ask the operator to run it." >&2
    exit 2
  fi
  exit 0
fi

cmd="$(J .tool_input.command)"; [ -n "$cmd" ] || cmd="${TOOL_INPUT:-${CODEX_TOOL_INPUT:-}}"
[ -n "$cmd" ] || exit 0
# Cheap prefilter: no git or no candidate verb means nothing to judge.
case "$cmd" in *git*) ;; *) exit 0 ;; esac
case "$cmd" in *reset*|*clean*|*checkout*|*switch*) ;; *) exit 0 ;; esac
persona="$(J .agent_type | tr -cd 'A-Za-z0-9:_.-')"
cwd="$(J .cwd)"; [ -n "$cwd" ] || cwd="$PWD"
# A payload cwd that does not exist cannot be where the command runs: fall back to the
# process cwd instead of failing open.
[ -d "$cwd" ] || cwd="$PWD"

# Shell-word tokenizer. One word per line; control lines: \001; (statement end),
# \001( and \001) (subshell); a word built from $, `...`, or a glob is prefixed \002.
TOKENIZE='
function flush() {
  if (have) {
    gsub(/\n/, " ", tok)
    if (skipword) skipword = 0
    else if (hwant) { hd[++nhd] = tok; hwant = 0 }
    else print (dyn ? "\002" : "") tok
  }
  tok = ""; have = 0; dyn = 0
}
function heredocs(   k, j, e, line) {
  for (k = 1; k <= nhd; k++) {
    while (i < n) {
      j = i + 1; e = index(substr(s, j), "\n")
      if (e == 0) { line = substr(s, j); i = n } else { line = substr(s, j, e - 1); i = j + e - 1 }
      sub(/^\t+/, "", line)
      if (line == hd[k]) break
    }
  }
  nhd = 0
}
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
  n = length(s); q = ""; tok = ""; have = 0; dyn = 0; skipword = 0; hwant = 0; nhd = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "\047") { if (c == "\047") q = ""; else tok = tok c; continue }
    if (q == "\"") {
      if (c == "\\" && i < n) { d = substr(s, i + 1, 1); if (d == "$" || d == "`" || d == "\"" || d == "\\" || d == "\n") { i++; if (d != "\n") tok = tok d; continue } }
      if (c == "\"") { q = ""; continue }
      if (c == "$" || c == "`") dyn = 1
      tok = tok c; continue
    }
    if (c == "\\") { if (i < n) { i++; d = substr(s, i, 1); if (d != "\n") { tok = tok d; have = 1 } } continue }
    if (c == "\047" || c == "\"") { q = c; have = 1; continue }
    if (c == "$") {
      have = 1; dyn = 1; d = substr(s, i + 1, 1)
      if (d == "(" || d == "{") {
        cl = (d == "(") ? ")" : "}"; depth = 0
        for (i++; i <= n; i++) { c = substr(s, i, 1); tok = tok c; if (c == d) depth++; else if (c == cl) { depth--; if (depth == 0) break } }
        continue
      }
      tok = tok c; continue
    }
    if (c == "`") { have = 1; dyn = 1; tok = tok c; for (i++; i <= n; i++) { c = substr(s, i, 1); tok = tok c; if (c == "`") break } continue }
    if (c == "*" || c == "?" || c == "[") { dyn = 1; tok = tok c; have = 1; continue }
    if (c == "#" && !have) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
    if (c == " " || c == "\t") { flush(); continue }
    if (c == "\n") { flush(); print "\001;"; if (nhd) heredocs(); continue }
    if (c == ">" || c == "<") {
      if (have && tok ~ /^[0-9]+$/) { tok = ""; have = 0; dyn = 0 } else flush()
      if (c == "<" && substr(s, i + 1, 1) == "<") {
        if (substr(s, i + 2, 1) == "<") { i += 2; skipword = 1; continue }
        i++; if (substr(s, i + 1, 1) == "-") i++
        hwant = 1; continue
      }
      while (substr(s, i + 1, 1) ~ /[<>&|]/) i++
      skipword = 1; continue
    }
    if (c == "&" && substr(s, i + 1, 1) == ">") { flush(); i++; while (substr(s, i + 1, 1) ~ /[>&]/) i++; skipword = 1; continue }
    if (c == ";" || c == "&" || c == "|") { flush(); print "\001;"; continue }
    if (c == "(" || c == ")") { flush(); print "\001" c; continue }
    tok = tok c; have = 1
  }
  flush()
}'
D=$'\002'; SEP=$'\001;'; OPEN=$'\001('; CLOSE=$'\001)'

# _res BASE TARGET: resolve a cd/-C target into R (empty = unresolved, reason in why).
_res(){ local b="$1" t="$2"; R=""
  case "$t" in "$D"*) why="the directory comes from a variable, command substitution, or glob"; return 0 ;; esac
  case "$t" in
    '~') R="$HOME" ;;
    '~/'*) R="$HOME/${t#\~/}" ;;
    '~'*) why="the directory uses ~user"; return 0 ;;
    /*) R="$t" ;;
    *) if [ -z "$b" ]; then why="the directory is relative to one that could not be resolved"; return 0; fi
       R="$b/$t" ;;
  esac
  if [ ! -d "$R" ]; then why="'$t' does not exist, so the cd may fail and leave the shell where it was"; R=""; fi
  return 0; }
# Primary checkout test: in a linked worktree git-dir is .git/worktrees/<name> while
# git-common-dir is .git, so they differ. Not a repo, or a missing dir, is not primary.
_primary(){ local d="$1" gd gcd
  gd="$(git -C "$d" rev-parse --git-dir 2>/dev/null)" && [ -n "$gd" ] || return 1
  gcd="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ "$(cd "$d" && cd "$gd" 2>/dev/null && pwd -P)" = "$(cd "$d" && cd "$gcd" 2>/dev/null && pwd -P)" ]; }

# _git FIRST: judge the git statement whose words after `git` start at index FIRST.
_git(){ local j="$1" n=${#tok[@]} t verb d=0 eff="$here"
  while [ "$j" -lt "$n" ]; do
    t="${tok[$j]}"
    case "$t" in
      -C) j=$((j + 1)); _res "$eff" "${tok[$j]:-}"; eff="$R" ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--super-prefix) j=$((j + 1)) ;;
      -*) ;;
      *) break ;;
    esac
    j=$((j + 1))
  done
  verb="${tok[$j]:-}"; verb="${verb#$D}"; j=$((j + 1))
  while [ "$j" -lt "$n" ]; do
    t="${tok[$j]#$D}"
    case "$verb:$t" in
      reset:--hard) d=1 ;;
      clean:--force|clean:-f*|clean:-[!-]*f*) d=1 ;;
      checkout:--force|checkout:-f*|checkout:-[!-]*f*|checkout:.|checkout:--) d=1 ;;
      switch:--force|switch:--discard-changes|switch:-f*|switch:-[!-]*f*) d=1 ;;
    esac
    j=$((j + 1))
  done
  [ "$d" = 1 ] || return 0
  if [ -z "$eff" ]; then unres="${why:-the directory could not be resolved}"; return 0; fi
  if _primary "$eff"; then hit="$eff"; fi
  return 0; }

# _stmt: act on the statement held in tok[] (a directory change, or a git command).
_stmt(){ local n=${#tok[@]} i=0 w a j
  [ "$n" -gt 0 ] || return 0
  while [ "$i" -lt "$n" ]; do
    w="${tok[$i]#$D}"
    case "$w" in
      [A-Za-z_]*=*|command|builtin|exec|nohup|time|env|sudo|do|then|else|elif|if|while|until|'{'|'!') i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  w="${tok[$i]#$D}"
  case "$w" in
    cd|pushd)
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        case "${tok[$j]}" in --) j=$((j + 1)); break ;; -?*) j=$((j + 1)) ;; *) break ;; esac
      done
      a="${tok[$j]:-}"
      if [ "$w" = pushd ]; then
        if [ -z "$a" ]; then here=""; why="pushd with no directory"; return 0; fi
        dstack+=("$here")
      fi
      if [ -z "$a" ]; then R="$HOME"
      elif [ "$a" = - ]; then
        if [ -n "$prev" ]; then R="$prev"; else R=""; why="cd - with no earlier directory in this command"; fi
      else _res "$here" "$a"; fi
      prev="$here"; here="$R" ;;
    popd)
      prev="$here"
      if [ "${#dstack[@]}" -gt 0 ]; then here="${dstack[${#dstack[@]}-1]}"; unset 'dstack[${#dstack[@]}-1]'
      else here=""; why="popd with no pushd earlier in this command"; fi ;;
    git) _git $((i + 1)) ;;
  esac
  return 0; }

here="$cwd"; prev=""; why=""; hit=""; unres=""; R=""
stack=(); dstack=(); tok=()
while IFS= read -r t; do
  case "$t" in
    "$SEP") _stmt; tok=() ;;
    "$OPEN") _stmt; tok=(); stack+=("$here") ;;
    "$CLOSE") _stmt; tok=()
      if [ "${#stack[@]}" -gt 0 ]; then here="${stack[${#stack[@]}-1]}"; unset 'stack[${#stack[@]}-1]'; fi ;;
    *) tok+=("$t") ;;
  esac
  [ -z "$hit$unres" ] || break
done < <(printf '%s' "$cmd" | awk "$TOKENIZE")
[ -n "$hit$unres" ] || _stmt

if [ -n "$hit" ]; then
  echo "orchestrate: refusing a destructive git op on the SHARED main checkout ($hit; orchestrate SKILL.md \"Hooks\", orchestrate ADR-0013): operate in a worktree; recreate, don't reset" >&2
  exit 2
fi
if [ -n "$unres" ]; then
  echo "orchestrate: refusing a destructive git op whose checkout cannot be resolved ($unres), so it may hit the SHARED main checkout (orchestrate SKILL.md \"Hooks\", orchestrate ADR-0013): run it from the worktree's own cwd with no cd, or name the worktree with an absolute git -C path" >&2
  exit 2
fi
exit 0
