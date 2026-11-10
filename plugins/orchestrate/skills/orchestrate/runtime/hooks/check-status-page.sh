#!/usr/bin/env bash
# PreToolUse (Artifact): the progress page is checked against the journal before it
# is published (ADR-0042).
#
# Fires only for a publish of a run's canonical page, `.agents/runs/orchestrate/status.html`.
# Runs `ledger.sh page-check --publish` on it and refuses the publish when the page
# contradicts the board (finished work shown as upcoming or as waiting on the operator,
# an answered ask still listed, an item shown done with no done row or approved verdict),
# when its finish dates disagree, when its stamp is not the publish time, when only the
# stamp and history changed although the journal moved, or when its code does not parse.
#
# Why a hook and not a line in the brief: the refresh rules were prose and were skipped on
# quiet ticks for about a day (2026-11-09/10); the stamp stayed fresh while the content
# went stale. This is a fact check (page vs journal), not a workflow gate.
#
# Contract (Claude Code): ALLOW = exit 0 with NO stdout; DENY = reasons on stderr + exit 2.
# Never errors on input it does not understand: any other tool call, any other file, a
# payload it cannot parse (no jq) is allowed. Other harnesses have no artifact surface.
# Not caught: the page published from a copy or a symlink under another name.
set -uo pipefail
in="$(cat 2>/dev/null || true)"
[ -n "$in" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
J(){ printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }
[ "$(J '.tool_input.action')" = "" ] || [ "$(J '.tool_input.action')" = publish ] || exit 0
[ "$(J '.tool_input.asset')" = true ] && exit 0
fp="$(J '.tool_input.file_path')"; [ -n "$fp" ] || exit 0
cwd="$(J '.cwd')"; [ -d "$cwd" ] || cwd="$PWD"
case "$fp" in /*) ;; *) fp="$cwd/$fp" ;; esac
[ -f "$fp" ] || exit 0
# Judge the canonical path (.., doubled slashes and symlinked directories resolved),
# and run the check from the repo root so ledger.sh finds this page's own journal
# whether or not the directory is a git checkout.
dir="$(cd "$(dirname "$fp")" 2>/dev/null && pwd -P)" || exit 0
fp="$dir/$(basename "$fp")"
case "$fp" in */.agents/runs/orchestrate/status.html) ;; *) exit 0 ;; esac
root="${fp%/.agents/runs/orchestrate/status.html}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$(cd "$root" && bash "$here/../ledger.sh" page-check --publish "$fp" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && exit 0
{
  echo "orchestrate: the progress page was not published. It disagrees with the run's journal or with itself:"
  printf '%s\n' "$out" | sed 's/^/  - /'
  [ "$rc" = 2 ] && echo "  - the page's DATA block could not be read"
  echo "Rebuild every field above the history from the journal, git and CI as they stand now (references/status-page-rules.md), add the history line last, stamp updated_at with date -u +%FT%TZ, then publish again."
} >&2
exit 2
