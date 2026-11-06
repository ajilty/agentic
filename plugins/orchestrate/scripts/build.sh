#!/usr/bin/env bash
# build.sh — generate the Claude Code plugin's native artifacts from the
# harness-neutral agents.yaml. Run by the maintainer after editing agents.yaml or
# a persona body; the output (agents/, hooks/hooks.json) is COMMITTED. The static
# manifest (.claude-plugin/plugin.json) and marketplace catalog are NOT generated.
#   ./scripts/build.sh        # writes into the plugin this script lives in
#
# All harness mapping logic lives in the repo-level scripts/harness-lib/ (ADR-0037)
# so any plugin compiles the same way; this driver only names the plugin's paths.
# HARNESS_LIB overrides the lib location (the drift-guard test rebuilds a tmp COPY
# of the plugin, where the relative default cannot resolve).
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$PLUGIN_ROOT/skills/orchestrate"
AGENTS="$SKILL_DIR/references/agents.yaml"
LIB="${HARNESS_LIB:-$(cd "$PLUGIN_ROOT/../.." && pwd)/scripts/harness-lib}"
. "$LIB/common.sh"; . "$LIB/claude-code.sh"
require_yq4

# 1) agents/<persona>.md: frontmatter (name/description/tools/tier/color/isolation) + persona body
mkdir -p "$PLUGIN_ROOT/agents"
for p in $(personas); do
  cc_agent_md "$p" "$PLUGIN_ROOT/agents/$p.md"
  mt="$(p_tier "$p" model)"; ef="$(p_tier "$p" effort)"
  echo "  agent  -> agents/$p.md   (tools: $(cc_tools "$p"), model: $(m="$(cc_model "$mt")"; echo "${m:-inherit}"), effort: ${ef}, color: $(cc_color "$mt" "$ef"))"
done

# 2) hooks/hooks.json — auto-registered when the plugin is enabled; derived from
#    the contract's hooks: block (the two survivors, ADR-0040).
mkdir -p "$PLUGIN_ROOT/hooks"
cc_hooks_json "$PLUGIN_ROOT/hooks/hooks.json" \
  '${CLAUDE_PLUGIN_ROOT}/skills/orchestrate/runtime/hooks'
echo "  hooks  -> hooks/hooks.json (derived from agents.yaml hooks: block)"
echo "build complete (agents/ + hooks/hooks.json regenerated from agents.yaml)"
