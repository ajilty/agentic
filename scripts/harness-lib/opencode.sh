# harness-lib/opencode.sh — compile the agents.yaml contract into OpenCode native
# surfaces (agent markdown, commands, the enforcement plugin). Source common.sh first.

# tools: is deprecated in favor of permission:, but still honored — emit BOTH:
# tools: for older builds, permission: (documented keys only: edit/bash/webfetch)
# as the current declarative deny layer. The plugin hook floor sits on top.
oc_tools() { local p="$1" read web write run rd=false gp=false gl=false wf=false wr=false ed=false bash=false
  read="$(p_cap "$p" read)"; web="$(p_cap "$p" web)"
  write="$(p_cap "$p" write)"; run="$(p_cap "$p" run)"
  [ "$read" = true ] && { rd=true; gp=true; gl=true; }; [ "$web" = true ] && wf=true
  case "$write" in full) wr=true; ed=true;; results|spec-only|results-only) wr=true;; esac   # results-only: scoped Write, no Edit (ADR-0014); write-scope hook confines the path
  case "$run" in full|tests-only) bash=true;; esac
  printf 'tools:\n  read: %s\n  grep: %s\n  glob: %s\n  webfetch: %s\n  write: %s\n  edit: %s\n  bash: %s\n' "$rd" "$gp" "$gl" "$wf" "$wr" "$ed" "$bash"
  printf 'permission:\n  edit: %s\n  bash: %s\n  webfetch: %s\n' \
    "$([ "$ed" = true ] && echo allow || echo deny)" \
    "$([ "$bash" = true ] && echo allow || echo deny)" \
    "$([ "$wf" = true ] && echo allow || echo deny)"; }

# agents.yaml tier -> OpenCode model id (provider-qualified). Defaults are the
# Anthropic ladder; override per tier via env for non-Anthropic rigs. Effort has
# no OpenCode agent-level equivalent, so the tier's effort half is carried by the
# model choice alone here.
oc_model() { case "$1" in
  economy)  echo "${ORCHESTRATE_OC_MODEL_ECONOMY:-anthropic/claude-haiku-4-5}" ;;
  standard) echo "${ORCHESTRATE_OC_MODEL_STANDARD:-anthropic/claude-sonnet-5}" ;;
  premium)  echo "${ORCHESTRATE_OC_MODEL_PREMIUM:-anthropic/claude-opus-5}" ;;
  *)        echo "" ;;   # unknown/empty tier -> omit model line (inherit session default)
esac; }

# Emit one subagent markdown (frontmatter rewritten to OpenCode keys + persona body).
oc_agent_md() { # <persona> <dest.md>
  local p="$1" dest="$2" m
  m="$(oc_model "$(p_tier "$p" model)")"
  { printf -- '---\ndescription: %s\nmode: subagent\n' "$(yaml_q "$(p_desc "$p")")"
    [ -n "$m" ] && printf 'model: %s\n' "$m"
    oc_tools "$p"; printf -- '---\n\n'; body "$(p_body "$p")"; } > "$dest"
}

# Emit one command, description PARSED from the source frontmatter, never restated
# (it had drifted three-for-three when hand-copied).
oc_command() { # <src.md> <dest.md>
  local desc; desc="$(yq --front-matter=extract '.description' "$1")"
  { printf -- '---\ndescription: %s\n---\n' "$(yaml_q "$desc")"; body "$1"; } > "$2"
}

# TS floor-call lines for hooks watching the given classes, contract wire order.
# Emits literal ${RT} for the plugin's template-literal interpolation.
oc_calls() { # <class-regex>
  local s
  while IFS= read -r s; do
    [ -n "$s" ] && printf '%s\n' "        await sh(\`\${RT}/hooks/$s\`, env);"
  done < <(hooks_watching "$1")
}

# Emit the enforcement plugin. The hook floor is DERIVED from the contract's
# watch classes (file-read -> read/grep/glob, shell -> bash, file-write ->
# write/edit/apply_patch); intents are documented in agents.yaml hooks:.
# dispatch-class hooks are the documented in-loop exception on OpenCode
# (no subagent-start event in the documented list, ADR-0034 — see the skill's
# OpenCode addendum); post-compaction -> session.compacted.
oc_plugin_ts() { # <dest.ts> <plugin_fn_name> <runtime_abs_path>
  local dest="$1" fn="$2" rt="$3" pc
  pc="$(hooks_watching 'post-compaction' | head -1)"
  cat > "$dest" <<TS
// $fn.ts — calls the shared runtime so policy stays single-source. GENERATED
// from agents.yaml (script + watch per hook); regenerate via the installer.
const RT = "$rt";
// Runtime helpers resolve by bare name in persona/router Bash; this prepends the
// runtime dir to PATH at plugin-load time as a fallback. The DOCUMENTED mechanism
// is the shell.env hook below, which runs on every shell OpenCode spawns
// (ADR-0018) — this load-time assignment only covers this plugin process itself.
process.env.PATH = \`\${RT}:\${process.env.PATH ?? ""}\`;

export const $fn = async ({ \$ }: any) => {
  // Run a hook script with a PER-CALL env object, never global process.env mutation
  // (which would race across concurrent tool calls). Nonzero exit throws (Bun \$
  // default) so the call is blocked — the documented fail-closed shape.
  const sh = async (script: string, env: Record<string, string>) => {
    await \$\`bash \${script}\`.env({ ...process.env, ...env });
  };
  return {
    "tool.execute.before": async (input: any, output: any) => {
      const tool = input?.tool ?? "";
      // Live-probed on 1.18.4 (opencode-live-tier): args ride the SECOND (output)
      // parameter — read tools carry filePath (some providers: path), bash carries
      // command, and OpenAI models write via apply_patch whose args carry patchText.
      const env = {
        RESOLVED_PATH: String(output?.args?.path ?? output?.args?.filePath ?? ""),
        TOOL_INPUT: String(output?.args?.command ?? output?.args?.patchText ?? ""),
      };
      if (["read","grep","glob"].includes(tool)) {
$(oc_calls 'file-read')
      }
      if (tool === "bash") {
$(oc_calls 'shell')
      }
      // apply_patch: the ACTUAL write tool observed live for OpenAI models — routed
      // so an unresolved path fails CLOSED (write-scope's default) instead of
      // bypassing confinement (multi-path apply_patch parsing: journaled follow-up).
      if (tool === "write" || tool === "edit" || tool === "apply_patch") {
$(oc_calls 'file-write')
      }
    },
    // Documented hook: injects PATH into every shell OpenCode spawns (ADR-0018),
    // so runtime helpers resolve by bare name inside persona Bash too.
    "shell.env": async (input: any, output: any) => {
      output.env.PATH = \`\${RT}:\${output.env.PATH ?? process.env.PATH ?? ""}\`;
    },
    // Automatic compaction recovery: reground + inject authoritative board; halt if
    // ambiguous. session.compacted is the DOCUMENTED post-compaction event.
    "session.compacted": async () => sh(\`\${RT}/hooks/$pc\`, {}),
  };
};
TS
}
