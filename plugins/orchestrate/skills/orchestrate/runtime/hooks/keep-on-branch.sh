#!/usr/bin/env bash
# PreToolUse (Bash): keep the IMPLEMENTER on its assigned worktree-agent branch.
#
# Input source: parse Claude Code's stdin JSON (tool_input.command, agent_type);
# fall back to env for Codex/OpenCode. Contract: ALLOW = exit 0 no stdout; DENY =
# stderr + exit 2. Self-guards; never errors.
#
# The off-branch-commit check reads the per-dispatch ASSIGNED_BRANCH from the
# on-disk active-writer record (ADR-0006; CC passes no router env to subagent
# hooks) and resolves the branch at the dir where the commit EFFECTIVELY runs —
# never this hook process's own cwd, which under CC is the main checkout, not the
# subagent shell's (live 2026-07-02 finding: a bare `git rev-parse` here read the
# main checkout's `master` and false-denied every legitimate worktree commit).
set -uo pipefail
# ADR-0032: a denial is FEEDBACK — journal it to the board (event "denied") so
# metrics/status/harvest see the friction without operator relay. Fires on ANY
# exit-2 path via the EXIT trap; never blocks, never alters the deny (explicit
# exit codes survive the trap), never touches stdout.
_journal_denial(){ rc=$?; [ "$rc" = 2 ] || return 0
  [ -f ".agents/runs/orchestrate/board.jsonl" ] || return 0   # wrong cwd -> skip
  rt="$(cd "$(dirname "$0")/.." && pwd)" || return 0
  n="$(printf '%.80s' "${cmd:-${p:-}}" | tr '\n' ' ' | tr '"\\' "'/")"
  bash "$rt/ledger.sh" append "{\"event\":\"denied\",\"hook\":\"keep-on-branch\",\"persona\":\"${persona:--}\",\"note\":\"$n\"}" >/dev/null 2>&1 || true
  return 0; }
trap _journal_denial EXIT
RT="$(cd "$(dirname "$0")/.." && pwd)"
in=""; [ -t 0 ] || in="$(cat 2>/dev/null || true)"
J(){ [ -n "$in" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }
persona="$(J .agent_type)"; [ -n "$persona" ] || persona="${PERSONA:-${CLAUDE_AGENT_TYPE:-${CODEX_AGENT:-}}}"
persona="${persona##*:}"   # strip plugin namespace: CC sends agent_type as <plugin>:<persona> (e.g. orchestrate:actuator)
[ "$persona" = implementer ] || exit 0
cmd="$(J .tool_input.command)"; [ -n "$cmd" ] || cmd="${TOOL_INPUT:-${CODEX_TOOL_INPUT:-}}"
case "$cmd" in
  *"git checkout -b"*|*"git switch -c"*|*"git branch "*)
    echo "orchestrate: branch is router-owned (SKILL §9b)" >&2; exit 2 ;;
esac
if printf '%s' "$cmd" | grep -q 'git commit'; then
  ab="${ASSIGNED_BRANCH:-$(bash "$RT/ledger.sh" writer-ctx get implementer assigned_branch)}"   # the IMPLEMENTER record only (ADR-0039)
  if [ -n "$ab" ]; then
    # Effective commit dir, in precedence order: an explicit `git -C <dir>`, else the
    # last `cd <dir>` in a compound command (the implementer's normal shape:
    # `cd <worktree> && git commit`), else the payload cwd (the subagent shell's),
    # else this process's cwd. NOT the assigned worktree's own HEAD — that is on the
    # assigned branch by construction, which would make this check vacuous and let a
    # main-checkout commit through. Best-effort dir parse (denylist posture, ADR-0002);
    # an unresolvable dir fails closed via the branch compare below.
    base="$(J .cwd)"; [ -n "$base" ] || base="$PWD"
    d="$(printf '%s' "$cmd" | grep -oE 'git +-C +[^ ]+' | head -1 | awk '{print $3}')"
    [ -n "$d" ] || d="$(printf '%s' "$cmd" | grep -oE '(^|[;&|] *)cd +[^ ;&|]+' | tail -1 | sed 's/.*cd  *//')"
    d="$(printf '%s' "$d" | tr -d '"'"'")"
    case "$d" in "") wd="$base";; /*) wd="$d";; *) wd="$base/$d";; esac
    head_branch="$(git -C "$wd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "$head_branch" != "$ab" ]; then
      echo "orchestrate: HEAD off assigned branch ($ab) — commit resolves to '$wd' on '${head_branch:-?}'" >&2; exit 2
    fi
  fi
fi
exit 0
