#!/usr/bin/env bash
# Write-ahead (writers): append 'dispatched' + take the lease BEFORE the writer runs,
# so a just-dispatched writer that left no dirty worktree is still visible to reground.
#
# FIRING (ADR-0011): Claude Code's SubagentStart event does NOT fire (live-confirmed),
# so under CC this runs as PreToolUse on the dispatch tool (matcher Task|Agent) — i.e.
# when the ROUTER dispatches a writer. The dispatched persona arrives as
# tool_input.subagent_type (the parent's own agent_type is null); Codex/OpenCode wire
# it to their subagent-start event, where the persona is agent_type / PERSONA env.
# The router writes active-writer.<persona>.json before dispatch (ADR-0006/0039), so the ticket/branch/
# targets are on disk when this fires. As a PreToolUse hook it must NEVER block the
# dispatch: ledger side-effects only, ALWAYS exit 0 — never decision JSON, never aborts.
set -uo pipefail
RT="$(cd "$(dirname "$0")/.." && pwd)"
in=""; [ -t 0 ] || in="$(cat 2>/dev/null || true)"
J(){ [ -n "$in" ] && command -v jq >/dev/null 2>&1 && printf '%s' "$in" | jq -r "$1 // empty" 2>/dev/null || true; }
# CC PreToolUse-on-dispatch: the dispatched persona is tool_input.subagent_type. Other
# harnesses (subagent-start): agent_type / env. Strip the plugin namespace either way.
persona="$(J .tool_input.subagent_type)"; [ -n "$persona" ] || persona="$(J .agent_type)"
[ -n "$persona" ] || persona="${PERSONA:-${CLAUDE_AGENT_TYPE:-${CODEX_AGENT:-}}}"
persona="${persona##*:}"   # strip plugin namespace: CC sends <plugin>:<persona>
case "$persona" in implementer|actuator) ;; *) exit 0 ;; esac
ts="$(date -u +%FT%TZ)"; d="${DISPATCH_ID:-$RANDOM}"
t="${TICKET:-$(bash "$RT/ledger.sh" writer-ctx get "$persona" ticket)}"   # the DISPATCHED persona's own record (ADR-0039)
[ -n "$t" ] || exit 0    # no ticket context -> nothing to write-ahead

if [ "$persona" = implementer ]; then
  b="${ASSIGNED_BRANCH:-$(bash "$RT/ledger.sh" writer-ctx get implementer assigned_branch)}"   # CC: no env; read the router's active-writer record (ADR-0006)
  bash "$RT/ledger.sh" append "{\"ts\":\"$ts\",\"ticket\":\"$t\",\"event\":\"dispatched\",\"persona\":\"implementer\",\"branch\":\"$b\",\"dispatch_id\":\"$d\"}"
  lease=".agents/runs/orchestrate/tickets/$t/lease"; mkdir -p "$(dirname "$lease")"
  printf '{"dispatch_id":"%s","session":"%s","pid":%s,"ts":"%s"}\n' "$d" "${SESSION_ID:-?}" "$$" "$ts" > "$lease"
  exit 0
fi

# actuator: ledger hygiene for the pre-apply gate — if a prod-level target lacks an
# operator ack, leave NO trace (no dispatched/lease) so reground isn't poisoned.
pts="${PROD_TARGETS:-$(bash "$RT/ledger.sh" writer-ctx get actuator prod_targets)}"
for key in $pts; do
  [ -f ".agents/runs/orchestrate/tickets/$t/ack-$(bash "$RT/ledger.sh" lease-key "$key")" ] || {
    bash "$RT/ledger.sh" append "{\"ts\":\"$ts\",\"ticket\":\"$t\",\"event\":\"gate-blocked\",\"persona\":\"actuator\",\"key\":\"$key\"}"
    exit 0
  }
done
bash "$RT/ledger.sh" append "{\"ts\":\"$ts\",\"ticket\":\"$t\",\"event\":\"dispatched\",\"persona\":\"actuator\",\"dispatch_id\":\"$d\"}"
for key in ${TARGETS:-$pts}; do   # CC: no TARGETS env -> lease the prod targets from the active-writer record
  bash "$RT/ledger.sh" lease-acquire "$t" "$key" || \
    bash "$RT/ledger.sh" append "{\"ts\":\"$ts\",\"ticket\":\"$t\",\"event\":\"lease-conflict\",\"persona\":\"actuator\",\"key\":\"$key\"}"
done
exit 0
