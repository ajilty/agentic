# Tier 3a — mechanical invocation against a LIVE local agent session. Proves the
# harness actually dispatches the right subagent and runs its tools — the one layer
# unit tests can't reach (they test scripts in isolation, not whether CC invokes
# the subagent). Inherently model-dependent → gated (not per-push), and best-effort: a fixed
# prompt forces the actuator + a Bash probe, which a capable model performs reliably.
#
# Isolation: temp cwd (the .agents/ ledger + any project .claude/ land in a throwaway
# repo) — pure filesystem isolation, no harness-config knob. Auth: a real local
# session (OAuth in ~/.claude) OR ANTHROPIC_API_KEY; skipped if neither is present.
if ! have_claude; then
  skip "tier3a invocation: claude CLI not on PATH"
elif ! { have_api || [ -d "$HOME/.claude" ]; }; then
  skip "tier3a invocation: no auth (set ANTHROPIC_API_KEY or log in)"
else
  repo="$(mk_repo)"; log="$(mk_tmp)/debug.log"
  prompt="Use the Task tool exactly once to dispatch the subagent named 'actuator'. Give the actuator this exact instruction: 'Do exactly two things, nothing else: (1) output a single line starting with TOOLS= followed by a comma-separated list of every tool name available to you; (2) use your Bash tool to run: echo ORCH_PROBE_OK. Then stop.' After it returns, output its response verbatim."
  out="$(printf '%s' "$prompt" | ( cd "$repo" && timeout 240 claude -p --plugin-dir "$PLUGIN_DIR" --debug --debug-file "$log" --allowedTools "Task,Bash" ) 2>&1)"

  # (1) The plugin's actuator subagent was actually dispatched by the harness.
  if grep -q 'agentType=orchestrate:actuator\|source=agent:custom:orchestrate:actuator' "$log" 2>/dev/null; then pass; else fail "harness dispatched the orchestrate:actuator subagent"; fi

  # (2) The actuator's Bash lane works end-to-end (capability honored at dispatch).
  case "$out" in *ORCH_PROBE_OK*) pass;; *) fail "actuator executed Bash (echo ORCH_PROBE_OK) under live dispatch";; esac

  # (3) Allowlist honored: actuator self-reports no source-write tools (soft signal).
  tools_line="$(printf '%s' "$out" | grep -oE 'TOOLS=[A-Za-z,]+' | head -1)"
  case "$tools_line" in *Write*|*Edit*) fail "actuator must NOT have Write/Edit (reported: $tools_line)";; *Bash*) pass;; *) skip "actuator tool self-report not parseable ($tools_line)";; esac
fi
