#!/usr/bin/env bash
# PostToolUse (Write|Edit): lint the just-written Markdown file with rumdl and feed
# findings straight back to the model so it fixes them in the same turn.
#
# Input: hook payload JSON on STDIN; the target file is tool_input.file_path.
# Only that one file is linted (see validate-syntax.sh for why never `git diff`).
#
# Contract: PASS = exit 0, no output. FINDINGS = rule lines on stderr, exit 2
# (PostToolUse exit 2 injects stderr into the model's context; the write already
# happened, so this cannot block, only correct). Tool failure (bad config, crash)
# is ALSO exit 2 with the error text: a silently broken guard is worse than a
# noisy one.
#
# Scope: files inside a git work tree only. A file whose directory is not inside a
# work tree (scratchpad, /tmp notes, auto-memory) is skipped silently (exit 0):
# it cannot be committed, and linting it is noise the model rightly ignores. Any
# file inside a work tree is linted wherever the checkout lives, so harvest clones
# and `dotfiles try` worktrees are covered.
#
# Check-only, never --fix: auto-fixing prose is how a wrapped line becomes a
# heading. --no-cache: rumdl otherwise litters .rumdl_cache/ dirs into every repo.
# Fail-open on missing jq/rumdl (lint assist, not a safety gate).
#
# Config: rumdl discovers .rumdl.toml / .markdownlint.{yaml,json} walking up from
# the FILE's directory to its .git boundary, then falls back to
# $XDG_CONFIG_HOME/rumdl/rumdl.toml (~/.config/rumdl/rumdl.toml). We cd to the
# file's directory so discovery is anchored to the file, not the hook's cwd.

set -u
MAX=20

command -v jq >/dev/null 2>&1 || exit 0
f=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$f" ] && [ -f "$f" ] || exit 0
case "$f" in *.md|*.markdown) ;; *) exit 0 ;; esac
command -v rumdl >/dev/null 2>&1 || exit 0

dir=$(dirname "$f"); base=$(basename "$f")
if command -v git >/dev/null 2>&1; then
  [ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 0
fi
# rumdl's [config warning] lines keep ANSI colour even under --color never; strip
# escapes so nothing but text reaches the model.
esc=$(printf '\033')
set -o pipefail   # so $? below is rumdl's exit, not sed's
out=$(cd "$dir" && rumdl check --no-cache --color never --quiet -- "$base" 2>&1 | sed "s/${esc}\[[0-9;]*m//g"); rc=$?

case "$rc" in
  0) exit 0 ;;
  1)
    total=$(printf '%s\n' "$out" | grep -c '^')
    {
      printf 'guards: markdown lint findings in %s (check-only; fix by hand, `rumdl explain <MDxxx>` for a rule)\n' "$f"
      printf '%s\n' "$out" | head -n "$MAX"
      [ "$total" -gt "$MAX" ] && printf '... %d more finding(s) not shown\n' "$((total - MAX))"
    } >&2
    exit 2 ;;
  *)
    printf 'guards: rumdl failed on %s (exit %s); fix the tool/config or this guard is a silent no-op\n%s\n' "$f" "$rc" "$(printf '%s\n' "$out" | head -n "$MAX")" >&2
    exit 2 ;;
esac
