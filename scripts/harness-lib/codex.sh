# harness-lib/codex.sh: compile the agents.yaml contract into Codex CLI native
# surfaces (agent TOMLs). Source common.sh first. Codex gets no hook wiring
# (ADR-0040): Claude Code gets every contract hook, OpenCode's plugin only the
# post-compaction one.

# capability vocabulary -> sandbox_mode (any write- or run-capable persona is
# workspace-write at the OS layer)
codex_sandbox() { local p="$1" w r
  w="$(p_cap "$p" write)"; r="$(p_cap "$p" run)"
  if [ "$w" = none ] && [ "$r" = none ]; then echo read-only; else echo workspace-write; fi; }
# agents.yaml tier -> codex model id (ADR-0041). The plugin ships no Codex model ID: a
# compiled one goes stale (the old gpt-5.x ladder was rejected outright on a ChatGPT
# account). standard/economy take the operator's ORCHESTRATE_STANDARD_MODEL /
# ORCHESTRATE_ECONOMY_MODEL at install time; unset, and always for premium, print nothing,
# so the role omits `model` and inherits the parent session's model.
codex_model() { case "$1" in
  economy)  echo "${ORCHESTRATE_ECONOMY_MODEL:-}" ;;
  standard) echo "${ORCHESTRATE_STANDARD_MODEL:-}" ;;
  *)        echo "" ;;   # premium / unknown / empty -> omit model line (inherit)
esac; }
# agents.yaml effort -> codex model_reasoning_effort, passed through unchanged. Codex
# accepts max on current models; acceptance is per model and decided server-side, so the
# lib does not second-guess it. Always emitted, even when model is omitted: a role that
# sets model alone keeps a previously resolved effort unvalidated.
codex_effort() { case "$1" in
  null|"") echo "" ;;    # absent in the contract -> omit (inherit)
  *)       echo "$1" ;;
esac; }
