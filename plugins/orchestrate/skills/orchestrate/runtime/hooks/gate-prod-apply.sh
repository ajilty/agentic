#!/usr/bin/env bash
# PreToolUse (actuator, Bash): pre-apply consequence gate (SKILL §6b), the hard
# floor — deny the actuator's commands while any prod-level mutation target lacks
# an operator ack.
#
# Input source: persona from Claude Code's stdin JSON (agent_type), env fallback.
# Contract: ALLOW = exit 0 no stdout; DENY = journal gate-blocked + stderr + exit 2.
#
# Per-dispatch context (TICKET, PROD_TARGETS) comes from env (Codex/OpenCode) or,
# under CC, from the router's on-disk ACTUATOR record (ADR-0006; one record per
# persona, ADR-0039, so a builder lane can never blank or retarget it). FAIL CLOSED:
# an actuator with no ticket from either source is unregistered and is denied on
# every command; the router registers it with `ledger.sh writer-ctx set <ticket>
# actuator <branch> [prod...]` before dispatch. A registered actuator with no prod
# targets is declared safe and runs freely.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
in=""; [ -t 0 ] || in="$(cat 2>/dev/null || true)"
J(){ [ -n "$in" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }
persona="$(J .agent_type)"; [ -n "$persona" ] || persona="${PERSONA:-${CLAUDE_AGENT_TYPE:-${CODEX_AGENT:-}}}"
persona="${persona##*:}"   # strip plugin namespace: CC sends agent_type as <plugin>:<persona> (e.g. orchestrate:actuator)
[ "$persona" = actuator ] || exit 0
# per-dispatch context: env (Codex/OpenCode) first, else the on-disk active-writer
# record the router wrote at dispatch (ADR-0006 — CC passes no router env to hooks).
t="${TICKET:-$(bash "$RT/ledger.sh" writer-ctx get actuator ticket)}"; ts="$(date -u +%FT%TZ)"
pts="${PROD_TARGETS:-$(bash "$RT/ledger.sh" writer-ctx get actuator prod_targets)}"
if [ -z "$t" ]; then
  bash "$RT/ledger.sh" append "{\"ts\":\"$ts\",\"ticket\":\"\",\"event\":\"gate-blocked\",\"persona\":\"actuator\",\"key\":\"unregistered\"}"
  echo "orchestrate: pre-apply gate — actuator has no active-writer record (register: ledger.sh writer-ctx set <ticket> actuator <branch> [prod...])" >&2; exit 2
fi
blocked=0; bkey=""
for key in $pts; do
  m=".agents/runs/orchestrate/tickets/$t/ack-$(bash "$RT/ledger.sh" lease-key "$key")"
  if [ ! -f "$m" ]; then
    bash "$RT/ledger.sh" append "{\"ts\":\"$ts\",\"ticket\":\"$t\",\"event\":\"gate-blocked\",\"persona\":\"actuator\",\"key\":\"$key\"}"
    blocked=1; bkey="$key"
  fi
done
[ "$blocked" = 1 ] && { echo "orchestrate: pre-apply gate — prod target requires operator ack ($bkey)" >&2; exit 2; }
exit 0
