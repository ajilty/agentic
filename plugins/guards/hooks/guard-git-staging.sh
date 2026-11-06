#!/usr/bin/env bash
# PreToolUse (Bash): deny git invocations that stage "everything" instead of named
# paths. The failure this guards against: an unrelated dirty file rides into a
# commit because `git add .` / `git commit -a` swept it in.
#
# Input: hook payload JSON on STDIN; the command is tool_input.command.
# Contract: ALLOW = exit 0, no output. DENY = one-line reason on stderr, exit 2
# (PreToolUse exit 2 blocks the call and shows stderr to the model, which then
# re-issues with explicit paths).
#
# Denied forms (after any git global options such as -C <dir>, -c k=v, --git-dir=):
#   git add  -A | --all | --[no-]ignore-removal | short clusters containing A or u
#            (-Av, -vA) | -u / --update unless the first token after `--` is a
#            literal, non-sweeping pathspec: non-empty, not starting with $ > < & | #
#            or 2> (`-u`, `-u .`, `-u -- .`, `-u -- $F`, `-u -- 2>&1` stay denied) |
#            pathspecs . ./ .. ../ * :/ :(top), quoted or not
#   git commit -a | --all | short clusters containing a (-am, -sam)
# Each simple command in a pipeline/chain/newline sequence is inspected
# separately, so `cd x && git add .` is caught.
#
# Quoted strings and heredoc bodies are treated as opaque text, so a commit
# message that mentions `-a` or `git add -A` is not a false positive: multi-word
# quoted strings collapse to a placeholder before tokenizing, and lines between a
# `<<WORD` marker and its terminator are skipped. Single-word quoted tokens keep
# their content so `git add "."` is still caught.
#
# Deliberately NOT denied: `git add -u -- <path>...` (bounded to the named paths),
# `git add -p/-N <path>`, read-only or worktree-only
# commands that take `.` (diff, log, checkout), `git stash -u`, and any non-git
# command including the `dotfiles` wrapper whose `add -u` flow is sanctioned in
# this environment. Not parsed: command substitution, `bash -c '...'`, eval.
# This guards the common case, not an adversary.
# Fail-open on missing jq (documented; jq is the plugin's one hard dependency).

set -u
set -f   # no globbing: `git add *` must be inspected as a literal token

command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

deny() {
  printf 'guards: blocked `%s` -- sweeping stage pulls unrelated files into the commit. Stage explicit paths (git add <file>... or git add -u -- <file>...) then commit without -a.\n' "$1" >&2
  exit 2
}

# Strip one layer of surrounding quotes from a token.
unquote() { local s="$1"; s=${s#[\"\']}; s=${s%[\"\']}; printf '%s' "$s"; }

# A literal pathspec is non-empty and is not an expansion ($), redirect (> < & 2>),
# pipe or comment (#): those can be empty or absent at runtime, which would make
# `git add -u --` pathless and sweep the whole tracked tree.
literal() {
  case "$1" in
    ''|'$'*|'>'*|'<'*|'&'*|'|'*|'#'*|[0-9]'>'*) return 1 ;;
  esac
  return 0
}

inspect() {
  local seg="$1" n i j k t sub a
  # Multi-word quoted strings become an opaque placeholder; single-word quoted
  # tokens survive so a quoted sweeping pathspec is still visible.
  local scan
  scan=$(printf '%s' "$seg" | sed -E "s/\"[^\"]*[[:space:]][^\"]*\"/Q/g; s/'[^']*[[:space:]][^']*'/Q/g")
  # shellcheck disable=SC2206
  local toks=($scan)
  n=${#toks[@]}; i=0
  while [ "$i" -lt "$n" ]; do
    t=${toks[$i]}; t=${t#\(}                 # `(git add .` subshell form
    if [ "$t" = git ] || [ "${t##*/}" = git ]; then
      j=$((i+1))
      while [ "$j" -lt "$n" ]; do            # skip git global options
        case "${toks[$j]}" in
          -C|-c|--git-dir|--work-tree|--namespace|--config-env) j=$((j+2)) ;;
          -*) j=$((j+1)) ;;
          *) break ;;
        esac
      done
      [ "$j" -lt "$n" ] || return 0
      sub=${toks[$j]}; k=$((j+1))
      case "$sub" in
        add)
          upd=0 dd=0 good=0 seen=0
          while [ "$k" -lt "$n" ]; do
            a=${toks[$k]}
            case "$a" in
              \"*|\'*)                        # quoted token: pathspec check only
                case "$(unquote "$a")" in
                  .|./|..|../|'*'|./'*'|:/|':/*'|':(top)'*) deny "$seg" ;;
                  *) if [ "$dd" = 1 ] && [ "$seen" = 0 ]; then
                       seen=1; literal "$(unquote "$a")" && good=1
                     fi ;;
                esac ;;
              -A|--all|--ignore-removal|--no-ignore-removal) deny "$seg" ;;
              -u|--update) upd=1 ;;         # allowed only with `-- <safe pathspec>`
              --) dd=1 ;;
              --*) ;;
              -*[Au]*) deny "$seg" ;;       # short clusters: -Av, -vA, -uv
              .|./|..|../|'*'|./'*'|:/|':/*'|':(top)'*) deny "$seg" ;;
              *) if [ "$dd" = 1 ] && [ "$seen" = 0 ]; then
                   seen=1; literal "$a" && good=1
                 fi ;;
            esac
            k=$((k+1))
          done
          [ "$upd" = 1 ] && [ "$good" = 0 ] && deny "$seg" ;;
        commit)
          while [ "$k" -lt "$n" ]; do
            a=${toks[$k]}
            case "$a" in
              \"*|\'*|Q) ;;                   # quoted text is never a flag
              -a|--all) deny "$seg" ;;
              --*) ;;
              -*a*) deny "$seg" ;;          # short clusters: -am, -sam
            esac
            k=$((k+1))
          done ;;
      esac
      return 0
    fi
    i=$((i+1))
  done
}

# Walk the command line by line, skipping heredoc bodies, and inspect each simple
# command (split on && || ; |) of the remaining lines.
hd=""
while IFS= read -r line; do
  if [ -n "$hd" ]; then
    stripped=${line#"${line%%[!	]*}"}       # heredoc terminator may be tab-indented (<<-)
    [ "$stripped" = "$hd" ] && hd=""
    continue
  fi
  case "$line" in
    *'<<'*)
      hd=$(printf '%s' "$line" | sed -nE "s/.*<<-?[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?.*/\1/p") ;;
  esac
  while IFS= read -r seg; do
    inspect "$seg"
  done <<EOF
$(printf '%s\n' "$line" | sed -E 's/(&&|\|\||;|\|)/\n/g')
EOF
done <<EOF
$cmd
EOF

exit 0
