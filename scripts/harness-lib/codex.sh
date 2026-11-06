# harness-lib/codex.sh: compile the agents.yaml contract into Codex CLI native
# surfaces (agent TOMLs). Source common.sh first. Codex gets no hook wiring: the
# contract's hooks target Claude Code and OpenCode only (ADR-0040).

# capability vocabulary -> sandbox_mode (any write- or run-capable persona is
# workspace-write at the OS layer)
codex_sandbox() { local p="$1" w r
  w="$(p_cap "$p" write)"; r="$(p_cap "$p" run)"
  if [ "$w" = none ] && [ "$r" = none ]; then echo read-only; else echo workspace-write; fi; }
# agents.yaml tier -> codex model id.  economy->mini, standard->5.4, premium->frontier.
codex_model() { case "$1" in
  economy)  echo gpt-5.4-mini ;;
  standard) echo gpt-5.4 ;;
  premium)  echo gpt-5.5 ;;
  *)        echo "" ;;   # unknown/empty tier -> omit model line (inherit session default)
esac; }
# agents.yaml effort -> codex model_reasoning_effort enum (low|medium|high|xhigh ONLY).
# `max` is NOT a valid codex value (API rejects it) -> map to the real ceiling, xhigh.
codex_effort() { case "$1" in
  low|medium|high|xhigh) echo "$1" ;;
  max)                   echo xhigh ;;
  *)                     echo "" ;;   # unknown/empty -> omit (inherit)
esac; }
