#!/usr/bin/env bash
# PreToolUse: confine each write-capable-but-not-a-writer persona to its OWN result
# path (agents.yaml `write_scope`, SKILL §5, ADR-0014; fail_closed):
#   planner     -> the committed spec/ADR + the per-ticket artifact dir
#   researcher  -> ONLY tickets/*/findings/_quarantine/*  (its RAW findings; the router
#                  reads from disk, runs the §4 gate, promotes to findings/<slug>.md)
#   verifier    -> ONLY tickets/*/verdicts/*              (its verdict + reasoning)
# A write anywhere else (source tree, configs, prod, the other persona's lane) is refused.
# The two writers (implementer/actuator) are governed by capability subtraction + branch_guard.
#
# Tool coverage. On Claude Code this hook's matcher is Write|Edit, so every call is a
# structured write (tool_input.file_path). On Codex ALL PreToolUse hooks share one
# matcher (Read|Edit|Write|Bash|apply_patch), so this hook also receives reads, shell,
# and the `apply_patch` write tool. We therefore act ONLY on writes:
#   - Write/Edit (+ legacy env-fallback): tool_input.file_path / RESOLVED_PATH.
#   - apply_patch (Codex top-level write): paths parsed from the patch in
#     tool_input.command (*** Add/Update/Delete File:, *** Move to:). ANY out-of-scope
#     target denies the whole patch (fail-closed).
#   - Any non-write tool (Read/Bash/...) is NOT this hook's concern -> allow (run-scope
#     governs the verifier's mutating Bash; reads are free). Without this, the shared
#     Codex matcher would make this hook deny a confined persona's reads and test-runs.
#
# Input: Claude Code/Codex deliver tool_name + tool_input + agent_type on STDIN as JSON
# (jq); env fallback (PERSONA/RESOLVED_PATH) for harnesses without it. Without jq under
# CC it degrades to allow (safe, not enforcing) — same posture as the sibling hooks.
#
# Contract: ALLOW = exit 0 with NO stdout; DENY = reason on stderr + exit 2. Self-guards
# on persona; never errors. Fail-closed: a write whose path can't be resolved denies, and
# any `..` is rejected (no climbing out of an allowed prefix). Accepted residual: prefixes
# are matched textually, so a path that merely *contains* an allowed segment is allowed —
# benign (still a result-shaped target, not source).
set -uo pipefail
# ADR-0032: a denial is FEEDBACK — journal it to the board (event "denied") so
# metrics/status/harvest see the friction without operator relay. Fires on ANY
# exit-2 path via the EXIT trap; never blocks, never alters the deny (explicit
# exit codes survive the trap), never touches stdout.
_journal_denial(){ rc=$?; [ "$rc" = 2 ] || return 0
  [ -f ".agents/runs/orchestrate/board.jsonl" ] || return 0   # wrong cwd -> skip
  rt="$(cd "$(dirname "$0")/.." && pwd)" || return 0
  n="$(printf '%.80s' "${cmd:-${p:-}}" | tr '\n' ' ' | tr '"\\' "'/")"
  bash "$rt/ledger.sh" append "{\"event\":\"denied\",\"hook\":\"write-scope\",\"persona\":\"${persona:--}\",\"note\":\"$n\"}" >/dev/null 2>&1 || true
  return 0; }
trap _journal_denial EXIT
in=""; [ -t 0 ] || in="$(cat 2>/dev/null || true)"
J(){ [ -n "$in" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }
persona="$(J .agent_type)"; [ -n "$persona" ] || persona="${PERSONA:-${CLAUDE_AGENT_TYPE:-${CODEX_AGENT:-}}}"
persona="${persona##*:}"   # strip plugin namespace: CC sends agent_type as <plugin>:<persona>
case "$persona" in planner|researcher|verifier) ;; *) exit 0 ;; esac

# Per-persona allow test (textual prefix; same posture as before). 0 = allowed.
allowed(){ case "$persona" in
  planner)    case "$1" in docs/specs/*|*/docs/specs/*|docs/adr/*|*/docs/adr/*|.agents/runs/orchestrate/tickets/*|*/.agents/runs/orchestrate/tickets/*) return 0 ;; esac ;;
  researcher) case "$1" in */tickets/*/findings/_quarantine/*) return 0 ;; esac ;;
  verifier)   case "$1" in */tickets/*/verdicts/*) return 0 ;; esac ;;
esac; return 1; }
deny(){ case "$persona" in
  planner)    echo "orchestrate: planner writes are confined to the spec/ADR artifact — docs/specs/, docs/adr/, or the per-ticket dir (refused: ${1:-<unresolved>})" >&2 ;;
  researcher) echo "orchestrate: researcher writes are confined to its RAW findings — tickets/<t>/findings/_quarantine/ (the router gates+promotes; refused: ${1:-<unresolved>})" >&2 ;;
  verifier)   echo "orchestrate: verifier writes are confined to its verdict — tickets/<t>/verdicts/ (refused: ${1:-<unresolved>})" >&2 ;;
esac; exit 2; }
# Confine one target path: reject `..`, then enforce the persona prefix (exits 2 on deny).
confine(){ case "$1" in
    ..|../*|*/..|*/../*) echo "orchestrate: $persona write path must not contain '..' (refused: $1)" >&2; exit 2 ;;
  esac
  allowed "$1" || deny "$1"; }

tool="$(J .tool_name)"
is_write(){ case "$1" in Write|Edit|MultiEdit|NotebookEdit|apply_patch) return 0 ;; *) return 1 ;; esac; }
# A non-write tool that merely carries a path (Codex shares the matcher) is not our concern.
if [ -n "$tool" ] && ! is_write "$tool"; then exit 0; fi

# apply_patch: confine EVERY target path in the patch body (tool_input.command).
cmd="$(J .tool_input.command)"
looks_patch=false; case "$cmd" in *'*** Begin Patch'*) looks_patch=true ;; esac
if [ "$tool" = apply_patch ] || [ "$looks_patch" = true ]; then
  paths="$(printf '%s\n' "$cmd" | sed -En 's/^\*\*\* (Add File|Update File|Delete File|Move to): //p')"
  [ -n "$paths" ] || deny "<apply_patch: no parseable target>"
  while IFS= read -r tp; do [ -n "$tp" ] && confine "$tp"; done <<PATCHEOF
$paths
PATCHEOF
  exit 0
fi

# Structured single-path write (Write/Edit, or legacy env-fallback with empty tool).
p="$(J .tool_input.file_path)"; [ -n "$p" ] || p="$(J .tool_input.path)"
[ -n "$p" ] || p="${RESOLVED_PATH:-${CODEX_TOOL_PATH:-}}"
[ -n "$p" ] && { confine "$p"; exit 0; }   # confine exits 2 on deny; reaching here = allowed

# A write tool with no resolvable target -> fail-closed.
deny "<unresolved>"
