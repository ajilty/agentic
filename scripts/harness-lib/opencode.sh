# harness-lib/opencode.sh: compile the agents.yaml contract into OpenCode native
# surfaces (agent markdown, commands, the PATH and compaction plugin). Source common.sh first.

# tools: is deprecated in favor of permission:, but still honored; emit BOTH:
# tools: for older builds, permission: (documented keys only: edit/bash/webfetch)
# as the current declarative deny layer.
oc_tools() { local p="$1" read web write run rd=false gp=false gl=false wf=false wr=false ed=false bash=false
  read="$(p_cap "$p" read)"; web="$(p_cap "$p" web)"
  write="$(p_cap "$p" write)"; run="$(p_cap "$p" run)"
  [ "$read" = true ] && { rd=true; gp=true; gl=true; }; [ "$web" = true ] && wf=true
  case "$write" in full) wr=true; ed=true;; results|spec-only|results-only) wr=true;; esac   # results-only: scoped Write, no Edit (ADR-0014)
  case "$run" in full|tests-only) bash=true;; esac
  printf 'tools:\n  read: %s\n  grep: %s\n  glob: %s\n  webfetch: %s\n  write: %s\n  edit: %s\n  bash: %s\n' "$rd" "$gp" "$gl" "$wf" "$wr" "$ed" "$bash"
  printf 'permission:\n  edit: %s\n  bash: %s\n  webfetch: %s\n' \
    "$([ "$ed" = true ] && echo allow || echo deny)" \
    "$([ "$bash" = true ] && echo allow || echo deny)" \
    "$([ "$wf" = true ] && echo allow || echo deny)"; }

# agents.yaml tier -> OpenCode model (ADR-0041). OpenCode has no alias or tier keyword,
# only concrete provider/model IDs, so the plugin ships none: standard/economy take the
# operator's ORCHESTRATE_STANDARD_MODEL / ORCHESTRATE_ECONOMY_MODEL, resolved here at
# install time (OpenCode does not apply {env:...} substitution inside agent markdown
# frontmatter, only in its JSON config). Unset, and always for premium, print nothing:
# the agent omits model and inherits the invoking session's model. Effort has no
# OpenCode agent-level equivalent, so the tier's effort half is not emitted here.
oc_model() { case "$1" in
  economy)  echo "${ORCHESTRATE_ECONOMY_MODEL:-}" ;;
  standard) echo "${ORCHESTRATE_STANDARD_MODEL:-}" ;;
  *)        echo "" ;;   # premium / unknown / empty -> omit model line (inherit)
esac; }

# Emit one subagent markdown (frontmatter rewritten to OpenCode keys + persona body with
# its craft skill inlined; persona_prompt in common.sh).
oc_agent_md() { # <persona> <dest.md>
  local p="$1" dest="$2" m
  m="$(oc_model "$(p_tier "$p" model)")"
  { printf -- '---\ndescription: %s\nmode: subagent\n' "$(yaml_q "$(p_desc "$p")")"
    [ -n "$m" ] && printf 'model: %s\n' "$(yaml_q "$m")"
    oc_tools "$p"; printf -- '---\n\n'; persona_prompt "$p"; } > "$dest"
}

# Emit one command, description PARSED from the source frontmatter, never restated
# (it had drifted three-for-three when hand-copied).
# A command source may inject text with the Claude Code plugin path to a runtime helper;
# OpenCode has no plugin root, so that path becomes the installed runtime's (third arg).
oc_command() { # <src.md> <dest.md> [runtime_abs_path]
  local desc rt="${3:-}"; desc="$(yq --front-matter=extract '.description' "$1")"
  rt="$(printf '%s' "$rt" | sed 's/[\\&#]/\\&/g')"          # literal in the sed replacement below
  { printf -- '---\ndescription: %s\n---\n' "$(yaml_q "$desc")"
    if [ -n "$rt" ]; then body "$1" | sed "s#\${CLAUDE_PLUGIN_ROOT}/bin/\\([a-z]*\\.sh\\)#$rt/\\1#g"; else body "$1"; fi; } > "$2"
}

# Emit the plugin: two behaviours only (ADR-0040). shell.env injects the runtime
# dir into PATH for every shell OpenCode spawns; session.compacted runs the
# contract's post-compaction hook script.
oc_plugin_ts() { # <dest.ts> <plugin_fn_name> <runtime_abs_path>
  local dest="$1" fn="$2" rt="$3" pc s
  # every post-compaction hook in the contract, in contract order
  pc=""; for s in $(hooks_watching 'post-compaction'); do pc="$pc
      await \$\`bash \${RT}/hooks/$s\`.env({ ...process.env });"; done
  cat > "$dest" <<TS
// $fn.ts: GENERATED from agents.yaml; regenerate via the installer.
const RT = "$rt";
// Fallback for this plugin process only. The documented mechanism is the
// shell.env hook below, which runs on every shell OpenCode spawns (ADR-0018).
process.env.PATH = \`\${RT}:\${process.env.PATH ?? ""}\`;

export const $fn = async ({ \$ }: any) => {
  return {
    // Injects PATH into every shell OpenCode spawns so runtime helpers resolve
    // by bare name inside persona Bash too.
    "shell.env": async (input: any, output: any) => {
      output.env.PATH = \`\${RT}:\${output.env.PATH ?? process.env.PATH ?? ""}\`;
    },
    // Automatic compaction recovery: reground + inject the authoritative board.
    // session.compacted is the documented post-compaction event.
    "session.compacted": async () => {$pc
    },
  };
};
TS
}
