SK="$HERE/.."   # plugins/orchestrate

# --- Compiled tool-allowlist (safety-critical): each generated agent carries
#     exactly the tools agents.yaml implies. Positive + negative assertions.
declare -A WANT=(
  [researcher]='Read,Grep,Glob,WebSearch,WebFetch,Write'
  [planner]='Read,Grep,Glob,Write'
  [implementer]='Read,Grep,Glob,Write,Edit,Bash'
  [verifier]='Read,Grep,Glob,Write,Bash'
  [actuator]='Read,Grep,Glob,Bash'
)
for p in "${!WANT[@]}"; do
  got="$(awk -F': ' '/^tools: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  assert_eq "$got" "${WANT[$p]}" "allowlist $p"
done

# --- Compiled model/effort tiers: horsepower right-sized by persona role. The abstract
#     contract tier (economy/standard/premium) compiles to a concrete CC model; effort
#     passes through. Judgment/correctness (planner/verifier) premium; reduction
#     (researcher) economy. (CLAUDE_CODE_SUBAGENT_MODEL=inherit can override model at
#     runtime — that's an operator env concern, not the compiled artifact.)
declare -A WANT_MODEL=( [researcher]=haiku [planner]=opus [implementer]=sonnet [verifier]=opus [actuator]=sonnet )
declare -A WANT_EFFORT=( [researcher]=medium [planner]=high [implementer]=high [verifier]=max [actuator]=high )
# Compiled terminal accent (CC-only presentation; the map lives in build.sh, NOT agents.yaml
# — see ADR-0007 / the contract's harness-neutrality header). The accent is a COST HEAT
# DERIVED from the tier above: cold = cheap, hot = expensive, so a fan-out board shows where
# the spend goes. Pinned here because the signal is only worth anything if it tracks the tier
# — a color that stopped following model/effort would be a lie about cost, not a cosmetic bug.
declare -A WANT_COLOR=( [researcher]=cyan [planner]=yellow [implementer]=green [verifier]=red [actuator]=green )
for p in "${!WANT_MODEL[@]}"; do
  gm="$(awk -F': ' '/^model: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  ge="$(awk -F': ' '/^effort: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  gc="$(awk -F': ' '/^color: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  assert_eq "$gm" "${WANT_MODEL[$p]}" "model tier $p"
  assert_eq "$ge" "${WANT_EFFORT[$p]}" "effort tier $p"
  assert_eq "$gc" "${WANT_COLOR[$p]}" "color $p"
done
# Monotonicity: the heat ladder must order the personas the way COST does. Duplicates are
# correct here (implementer/actuator are the same tier, so they must look the same); what
# must never happen is a cheap persona reading hotter than an expensive one. This is the
# check that catches a well-meaning "let's make the actuator red" from re-tainting the
# scale with a second, contradictory meaning.
declare -A HEAT=( [cyan]=1 [green]=2 [yellow]=3 [red]=4 )
ladder_ok=1
for pair in "researcher<implementer" "implementer=actuator" "actuator<planner" "planner<verifier"; do
  a="${pair%%[<=]*}"; b="${pair##*[<=]}"; op="${pair//[a-z]/}"
  ha="${HEAT[${WANT_COLOR[$a]}]:-0}"; hb="${HEAT[${WANT_COLOR[$b]}]:-0}"
  case "$op" in
    '<') [ "$ha" -lt "$hb" ] || { ladder_ok=0; echo "  heat: $a ($ha) must be cooler than $b ($hb)" >&2; };;
    '=') [ "$ha" -eq "$hb" ] || { ladder_ok=0; echo "  heat: $a ($ha) and $b ($hb) are the same tier, must match" >&2; };;
  esac
done
[ "$ladder_ok" = 1 ] && pass || fail "color heat ladder must follow cost order"
# Negatives (disk-first read lane, ADR-0014): read-only personas now carry a
# PATH-SCOPED Write (results-only: findings/_quarantine for researcher, verdicts
# for verifier; enforced by write-scope.sh) so their results survive interruption.
# They must still NOT carry Edit (they create new result files, never edit source),
# and the actuator (writes live state via run, not source via Write) carries neither.
for p in researcher verifier; do
  if grep -qE '^tools: .*Edit' "$SK/agents/$p.md"; then fail "$p must not have Edit (results-only Write, no source edits)"; else pass; fi
done
if grep -qE '^tools: .*(Write|Edit)' "$SK/agents/actuator.md"; then fail "actuator must not have Write/Edit"; else pass; fi

# --- Hook-path resolution: every ${CLAUDE_PLUGIN_ROOT}/... command in hooks.json
#     resolves to an executable script inside the plugin.
ok=1
while IFS= read -r rel; do
  [ -x "$SK/$rel" ] || { ok=0; echo "  unresolved/non-exec hook: $rel" >&2; }
done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[^"]+\.sh' "$SK/hooks/hooks.json" | sed 's#${CLAUDE_PLUGIN_ROOT}/##' | sort -u)
[ "$ok" = 1 ] && pass || fail "hooks.json paths resolve to executable scripts"

# --- Contract parity (root-cause guard): EVERY hook declared in agents.yaml's
#     hooks: block must carry its script: + watch: wire map, be materialized
#     (script exists + executable), AND be wired into hooks.json. The name->file
#     map lives IN the contract (single source); this checks it is complete and
#     honored. This is the check that would have caught write_scope being declared
#     (fail_closed) but never filed or wired — and guard-merge-base being wired
#     on one harness but absent from the contract.
if have_yq4; then
  AG="$SK/skills/orchestrate/references/agents.yaml"
  HJ="$SK/hooks/hooks.json"
  HD="$SK/skills/orchestrate/runtime/hooks"
  for name in $(yq '.hooks | keys | .[]' "$AG"); do
    f="$(yq ".hooks.$name.script" "$AG")"
    w="$(yq ".hooks.$name.watch | length" "$AG")"
    if [ -z "$f" ] || [ "$f" = null ]; then fail "declared hook '$name' has no script: field in agents.yaml (the contract IS the map)"; continue; fi
    if [ "$w" = 0 ] || [ "$w" = null ]; then fail "declared hook '$name' has no watch: classes in agents.yaml"; continue; fi
    if [ ! -x "$HD/$f" ]; then fail "declared hook '$name' -> $f missing or non-executable"; continue; fi
    if grep -qF -e "/$f\"" -e "/$f\\\"" "$HJ"; then pass; else fail "declared hook '$name' ($f) not wired in hooks.json"; fi
  done
else
  echo "(skip contract-parity: $YQ4_SKIP)"
fi

# --- Drift guard: committed artifacts must equal a fresh build. Copy the plugin
#     to a temp tree, rebuild there, diff the generated files. Skips without yq.
#     HARNESS_LIB points the tmp copy at the real repo-level lib (ADR-0037): the
#     lib is build-time-only and lives OUTSIDE the plugin, so the copied driver's
#     relative default cannot resolve it.
if have_yq4; then
  t="$(mktemp -d)"; cp -r "$SK/." "$t/"
  ( HARNESS_LIB="$(cd "$SK/../.." && pwd)/scripts/harness-lib" bash "$t/scripts/build.sh" >/dev/null 2>&1 )
  for f in agents/researcher.md agents/planner.md agents/implementer.md agents/verifier.md agents/actuator.md hooks/hooks.json; do
    if diff -q "$SK/$f" "$t/$f" >/dev/null 2>&1; then pass; else fail "drift: committed $f != fresh build (run scripts/build.sh)"; fi
  done
  rm -rf "$t"
else
  echo "(skip drift guard: $YQ4_SKIP)"
fi

# --- Manifest validity: plugin.json + marketplace.json parse; names align;
#     marketplace source resolves to a real dir. Skips without yq.
if have_yq4; then
  pj="$SK/.claude-plugin/plugin.json"
  mp="$(cd "$SK/../.." && pwd)/.claude-plugin/marketplace.json"
  assert_eq "$(yq -p=json -r '.name' "$pj")" "orchestrate" "plugin.json name"
  assert_eq "$(yq -p=json -r '.plugins[0].name' "$mp")" "orchestrate" "marketplace plugin name"
  src="$(yq -p=json -r '.plugins[0].source' "$mp")"
  rdir="$(cd "$SK/../.." && pwd)/${src#./}"
  if [ -d "$rdir" ] && [ -f "$rdir/.claude-plugin/plugin.json" ]; then pass; else fail "marketplace source '$src' does not resolve to a plugin dir"; fi
else
  echo "(skip manifest validity: $YQ4_SKIP)"
fi

# --- SKILL §2a' dispatch tier table vs the contract: the table is the OPERATIVE
#     tier carrier on Claude Code (the router passes model/effort explicitly at
#     dispatch — registered agent model: does not reliably bind), so it must agree
#     with agents.yaml. The researcher rows are dispatch FLAVORS: the sweep row is
#     the tier baseline (economy), judgment/troubleshooter are documented
#     escalations — so researcher pins to its sweep row, everyone else exactly.
if have_yq4; then
  AGY="$SK/skills/orchestrate/references/agents.yaml"
  SKM="$SK/skills/orchestrate/SKILL.md"
  cc_tier_model() { case "$1" in economy) echo haiku;; standard) echo sonnet;; premium) echo opus;; esac; }
  row_for() { grep -E "^\| *$1 *\|" "$SKM" | head -1; }
  # The tier column is relative with today's concrete model in parens — "T-1 (opus)",
  # "floor (haiku)" — so the cross-check reads the parenthesized model.
  cell_model() { m="$(printf '%s' "$1" | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
    case "$m" in *\(*\)*) m="${m#*\(}"; m="${m%%\)*}";; esac; printf '%s' "$m"; }
  for p in planner implementer actuator verifier; do
    want_m="$(cc_tier_model "$(yq ".personas.$p.tier.model" "$AGY")")"
    want_e="$(yq ".personas.$p.tier.effort" "$AGY")"
    row="$(row_for "$p")"
    got_m="$(cell_model "$row")"
    got_e="$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')"
    assert_eq "$got_m" "$want_m" "SKILL §2a' model for $p tracks agents.yaml"
    assert_eq "$got_e" "$want_e" "SKILL §2a' effort for $p tracks agents.yaml"
  done
  base_row="$(grep -E '^\| *researcher — sweep' "$SKM" | head -1)"
  want_m="$(cc_tier_model "$(yq '.personas.researcher.tier.model' "$AGY")")"
  got_m="$(cell_model "$base_row")"
  assert_eq "$got_m" "$want_m" "SKILL §2a' researcher baseline (sweep) tracks agents.yaml tier"
else
  echo "(skip §2a' tier-table parity: $YQ4_SKIP)"
fi

# --- Clarification binding (§2b front-door gate): the router-prose config that binds
#     WHICH clarification skill fires must stay present and order-matched. Nothing
#     compiles it per-harness, so without this guard it can silently drift or vanish
#     (the gate would fall through to inline on every ambiguous goal, unnoticed). It
#     lives under conventions:, not top-level — a wrong path once read it as ABSENT.
if have_yq4; then
  AGY="$SK/skills/orchestrate/references/agents.yaml"
  got_cs="$(yq '.conventions.clarification_skills | join(",")' "$AGY" 2>/dev/null)"
  assert_eq "$got_cs" "grill-with-docs,grill-me,brainstorming,inline" "clarification_skills present + order-matched (§2b)"
else
  echo "(skip clarification binding: $YQ4_SKIP)"
fi
