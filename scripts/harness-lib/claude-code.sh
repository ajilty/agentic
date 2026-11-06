# harness-lib/claude-code.sh — compile the agents.yaml contract into Claude Code
# native artifacts (plugin agents/*.md + hooks/hooks.json). Source common.sh first.

# capability vocabulary -> CC tool allowlist
cc_tools() { local p="$1" t=()
  [ "$(p_cap "$p" read)" = true ] && t+=(Read Grep Glob)
  [ "$(p_cap "$p" web)"  = true ] && t+=(WebSearch WebFetch)
  case "$(p_cap "$p" write)" in full) t+=(Write Edit);; results) t+=(Write);; esac
  case "$(p_cap "$p" run)" in full|tests-only) t+=(Bash);; esac
  ( IFS=, ; echo "${t[*]}" ); }

# Abstract horsepower tier (agents.yaml, portable) -> concrete CC model. Effort passes
# through (low|medium|high|xhigh|max are CC-native). Keeps the contract free of vendor
# model IDs; each harness lib maps the same tier to its own models.
cc_model() { case "$1" in economy) echo haiku;; standard) echo sonnet;; premium) echo opus;; *) echo "";; esac; }

# Terminal accent for the subagent, Claude Code's `color:` frontmatter field. Presentation
# only — it grants nothing and subtracts nothing — so it lives HERE in the CC layer, not
# in agents.yaml: `color` is one harness's vocabulary (Codex/OpenCode agent frontmatter has
# no equivalent) and the contract stays free of it (ADR-0007).
#
# The accent is a COST HEAT read straight off the tier, so a fan-out board shows at a glance
# where the spend is going: cold = cheap, hot = expensive. Derived, never hand-assigned —
# retune a tier in agents.yaml and the color follows, so it cannot drift into a lie. Model
# tier is the dominant cost term; extended thinking (xhigh|max) bumps one rung because the
# reasoning tokens it buys are billed as output.
#   cyan   economy | green standard | yellow premium | red premium + extended thinking
# Same tier -> same color BY DESIGN: two personas that cost the same should look the same.
cc_color() { local c
  case "$1" in economy) c=1;; standard) c=2;; premium) c=3;; *) echo ""; return;; esac
  case "$2" in xhigh|max) c=$((c+1));; esac
  case "$c" in 1) echo cyan;; 2) echo green;; 3) echo yellow;; *) echo red;; esac; }

# Emit one plugin agent markdown (frontmatter from the contract + persona body).
cc_agent_md() { # <persona> <dest.md>
  local p="$1" dest="$2" mt ef cl iso extra=""
  mt="$(p_tier "$p" model)"; ef="$(p_tier "$p" effort)"; cl="$(cc_color "$mt" "$ef")"
  iso="$(yq ".personas.$p.isolation" "$AGENTS")"
  [ "$mt" != null ] && [ -n "$mt" ] && extra="${extra}model: $(cc_model "$mt")\n"
  [ "$ef" != null ] && [ -n "$ef" ] && extra="${extra}effort: $ef\n"
  [ -n "$cl" ] && extra="${extra}color: $cl\n"
  [ "$iso" != null ] && [ -n "$iso" ] && extra="${extra}isolation: $iso\n"
  { printf -- '---\nname: %s\ndescription: %s\ntools: %s\n%b---\n\n' \
      "$p" "$(p_desc "$p")" "$(cc_tools "$p")" "$extra"
    body "$(p_body "$p")" | sed '/./,$!d'; } > "$dest"   # drop leading blanks (MD012)
}

# Emit hooks.json derived from the contract's hooks: block (script + watch, in
# document order). CC watch-class mapping: shell -> PreToolUse matcher "Bash",
# post-compaction -> SessionStart matcher "compact". A class with no hooks emits
# no group, so the JSON is valid for any subset of the contract.
cc_hooks_json() { # <out.json> <hook-path-prefix>
  local out="$1" H="$2" cls s
  _cc_group() { # <matcher> <script>...  (one group, no trailing comma)
    local m="$1" first=1; shift
    printf '      { "matcher": "%s", "hooks": [\n' "$m"
    for s in "$@"; do
      [ "$first" = 1 ] || printf ',\n'
      first=0; printf '        { "type": "command", "command": "\\"%s/%s\\"" }' "$H" "$s"
    done
    printf ' ] }'
  }
  _cc_event() { # <Event> <matcher> <class-regex>; prints nothing when the class is empty
    local ev="$1" m="$2" arr
    arr=($(hooks_watching "$3"))
    [ "${#arr[@]}" -gt 0 ] || return 0
    [ -z "$_cc_sep" ] || printf ',\n'
    _cc_sep=1
    printf '    "%s": [\n' "$ev"; _cc_group "$m" "${arr[@]}"; printf '\n    ]'
  }
  local _cc_sep=""
  {
    printf '{\n  "hooks": {\n'
    _cc_event PreToolUse Bash 'shell'
    _cc_event SessionStart compact 'post-compaction'
    printf '\n  }\n}\n'
  } > "$out"
}
