# harness-lib/common.sh — harness-agnostic helpers for compiling a plugin's
# agents.yaml contract into native harness artifacts. Sourced by per-plugin
# drivers (plugins/<name>/scripts/{build,install-*}.sh); pairs with one of the
# per-harness siblings (claude-code.sh / codex.sh / opencode.sh).
#
# Caller contract (globals the sourcing driver must set):
#   AGENTS    — path to the plugin's agents.yaml
#   SKILL_DIR — path to the plugin's skill source dir (SKILL.md + references/ + runtime/)
# No plugin names are hardcoded anywhere in this lib (ADR-0037): a second plugin
# reuses it by setting the globals and calling the same functions.

require_yq4() {
  yq --version 2>/dev/null | grep -qE 'mikefarah|version v?4\.' \
    || { echo "FATAL: yq (v4, mikefarah) required — the Python (kislyuk) yq emits JSON-quoted scalars and will not work." >&2; exit 1; }
}

# Strip the persona file's frontmatter; the body is the role text every harness embeds.
body() { awk 'f==2{print} /^---[[:space:]]*$/{f++}' "$1"; }

# Drop leading and trailing blank lines (one blank between sections, MD012).
trim_blank() { awk '{l[NR]=$0} NF{if(!s)s=NR; e=NR} END{for(i=s;s&&i<=e;i++)print l[i]}'; }

# Single-quoted YAML scalar (colons in prose are common; bare emission broke on "Flags: ...").
yaml_q() { printf "'%s'" "${1//\'/\'\'}"; }

# --- Contract accessors (read agents.yaml; document order is wire order) -----
personas() { yq '.personas | keys | .[]' "$AGENTS"; }
p_desc()   { yq ".personas.$1.description" "$AGENTS"; }
p_body()   { echo "$SKILL_DIR/references/$(yq ".personas.$1.body" "$AGENTS")"; }
p_cap()    { yq ".personas.$1.capabilities.$2" "$AGENTS"; }
p_tier()   { yq ".personas.$1.tier.$2" "$AGENTS"; }
# Craft skill the persona carries (agents.yaml craft:), or empty when it has none.
p_craft()  { yq ".personas.$1.craft // \"\"" "$AGENTS"; }
# The craft skill's SKILL.md: a sibling skill dir next to SKILL_DIR (skills/<craft>/).
p_craft_file() { echo "$(dirname "$SKILL_DIR")/$(p_craft "$1")/SKILL.md"; }

# The persona's full instructions, the text every harness embeds: the persona body,
# then (when the contract names one) the craft skill's body, frontmatter stripped,
# under a "Craft guidance" heading. The craft's headings drop two levels so they nest
# under that heading (fenced code is left alone). A craft: naming a skill that does
# not exist is fatal, never a silently thinner persona.
persona_prompt() { # <persona>
  local p="$1" c f
  body "$(p_body "$p")" | trim_blank
  c="$(p_craft "$p")"; [ -n "$c" ] || return 0
  f="$(p_craft_file "$p")"
  [ -f "$f" ] || { echo "FATAL: persona '$p' names craft '$c' but $f does not exist" >&2; return 1; }
  printf '\n## Craft guidance (`%s`)\n\n' "$c"
  printf 'Included from the `%s` craft skill when this definition was generated.\n' "$c"
  printf 'Apply it as method; the persona brief above prevails on any conflict.\n\n'
  body "$f" | trim_blank \
    | awk '/^[[:space:]]*(```|~~~)/{fence=!fence} !fence && /^#+[[:space:]]/{$0="##" $0} {print}'
}
# Hooks whose watch: classes match the regex — script filenames, contract order.
hooks_watching() { yq ".hooks[] | select([.watch[] | test(\"^($1)$\")] | any) | .script" "$AGENTS"; }
# Same selection, but the contract hook NAMES (for applies_to/matcher lookups).
hooks_watching_names() { yq ".hooks | to_entries | .[] | select([.value.watch[] | test(\"^($1)$\")] | any) | .key" "$AGENTS"; }
hook_script()  { yq ".hooks.$1.script" "$AGENTS"; }
hook_matcher() { yq ".hooks.$1.applies_to | join(\"|\")" "$AGENTS"; }

# --- Installer arg parsing (sets SCOPE + OVERRIDE) ---------------------------
parse_scope_args() {
  SCOPE=user; OVERRIDE=""
  while [ $# -gt 0 ]; do case "$1" in
    --scope) SCOPE="${2:?}"; shift 2 ;;
    --dir)   OVERRIDE="${2:?}"; shift 2 ;;
    *) echo "usage: $0 [--scope user|project] [--dir <path>]" >&2; exit 64 ;;
  esac; done
}

# Resolve the cross-tool Agent Skills root for SCOPE/OVERRIDE (ADR-0034):
# user -> ~/.agents/skills (or OVERRIDE/.agents/skills), project -> $PWD/.agents/skills.
resolve_skills_root() {
  case "$SCOPE" in
    user)    SKILLS_ROOT="${OVERRIDE:+$OVERRIDE/.agents/skills}"; SKILLS_ROOT="${SKILLS_ROOT:-$HOME/.agents/skills}" ;;
    project) SKILLS_ROOT="${OVERRIDE:-$PWD}/.agents/skills" ;;
    *) echo "scope must be user|project" >&2; exit 64 ;;
  esac
}

# Install ONE copy of the skill (SKILL.md + references/ + runtime/) to a dest dir,
# appending the harness dispatch addendum from stdin. SKILL.md is copied verbatim
# FIRST (a skill file must OPEN with its YAML frontmatter — a prepended banner
# would break skills discovery), then the addendum lands (generated distribution,
# ADR-0007/0034 — never a symlink). Idempotent re-runs overwrite in place.
install_skill() { # <dest_skill_dir>   (addendum on stdin)
  local dest="$1"
  mkdir -p "$dest/runtime" "$dest/references"
  cp -r "$SKILL_DIR/runtime/." "$dest/runtime/"
  cp -r "$SKILL_DIR/references/." "$dest/references/"
  chmod +x "$dest/runtime"/*.sh
  for h in "$dest/runtime"/hooks/*.sh; do [ -e "$h" ] && chmod +x "$h"; done
  cat "$SKILL_DIR/SKILL.md" > "$dest/SKILL.md"
  cat >> "$dest/SKILL.md"
}
