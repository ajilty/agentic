# Tier 3 (Codex model tiers): the generated Codex roles follow ADR-0041. The plugin ships
# no Codex model ID: with ORCHESTRATE_STANDARD_MODEL / ORCHESTRATE_ECONOMY_MODEL unset,
# every role omits `model` and inherits the parent session's model (the only tier a
# ChatGPT-account Codex accepted when this was written). Effort is always emitted and
# passed through unchanged, so the roles stay differentiated by effort: the verifier
# (high) above the researcher (medium). TOML inspection is the assertion.
if ! have_codex; then
  skip "codex model-tier: codex CLI not on PATH"
else
  ch="$(mk_codex_home)"
  ( unset ORCHESTRATE_STANDARD_MODEL ORCHESTRATE_ECONOMY_MODEL; codex_install "$ch" )
  vf="$ch/agents/verifier.toml"; rf="$ch/agents/researcher.toml"
  if [ ! -f "$vf" ] || [ ! -f "$rf" ]; then
    fail "codex model-tier: installer produced no verifier/researcher role"
  else
    _key(){ grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -1 | sed -E 's/.*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }
    assert_eq "$(_key "$vf" model)" "" "codex model-tier: verifier inherits (no model line)"
    assert_eq "$(_key "$rf" model)" "" "codex model-tier: researcher inherits with no ORCHESTRATE_ECONOMY_MODEL"
    assert_eq "$(_key "$vf" model_reasoning_effort)" "high"   "codex model-tier: verifier effort"
    assert_eq "$(_key "$rf" model_reasoning_effort)" "medium" "codex model-tier: researcher effort"
  fi
  cd /
fi
