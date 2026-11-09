SK="$HERE/.."   # plugins/orchestrate

# --- Compiled tool-allowlist (safety-critical): each generated agent carries
#     exactly the tools agents.yaml implies. Positive + negative assertions.
# One row per persona: persona|tools|model|effort|color (an empty model means no model:
# line). A plain table, not associative arrays, so the suite runs under macOS bash 3.2.
WANT_ROWS='researcher|Read,Grep,Glob,WebSearch,WebFetch,Write|haiku|medium|cyan
planner|Read,Grep,Glob,Write||high|yellow
implementer|Read,Grep,Glob,Write,Edit,Bash|sonnet|medium|green
verifier|Read,Grep,Glob,Write,Bash||high|yellow
actuator|Read,Grep,Glob,Bash|sonnet|high|green'
want(){ printf '%s\n' "$WANT_ROWS" | awk -F'|' -v p="$1" -v k="$2" '$1 == p { print $k }'; }   # want <persona> <2..5>
for p in researcher planner implementer verifier actuator; do
  got="$(awk -F': ' '/^tools: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  assert_eq "$got" "$(want "$p" 2)" "allowlist $p"
done

# --- Compiled model/effort tiers: horsepower right-sized by persona role (ADR-0041). The
#     abstract contract tier compiles to a Claude Code alias: premium emits NO model line
#     (the persona inherits the main loop, so it can never run above it), standard -> sonnet,
#     economy -> haiku. Effort passes through unchanged. An empty WANT_MODEL means "no
#     model: line". (CLAUDE_CODE_SUBAGENT_MODEL can still override at runtime; that is an
#     operator env concern, not the compiled artifact.)
# Compiled terminal accent (CC-only presentation; the map lives in build.sh, NOT agents.yaml
# — see ADR-0007 / the contract's harness-neutrality header). The accent is a COST HEAT
# DERIVED from the tier above: cold = cheap, hot = expensive, so a fan-out board shows where
# the spend goes. Pinned here because the signal is only worth anything if it tracks the tier
# — a color that stopped following model/effort would be a lie about cost, not a cosmetic bug.
for p in researcher planner implementer verifier actuator; do
  gm="$(awk -F': ' '/^model: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  ge="$(awk -F': ' '/^effort: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  gc="$(awk -F': ' '/^color: /{print $2; exit}' "$SK/agents/$p.md" 2>/dev/null)"
  assert_eq "$gm" "$(want "$p" 3)" "model tier $p"
  assert_eq "$ge" "$(want "$p" 4)" "effort tier $p"
  assert_eq "$gc" "$(want "$p" 5)" "color $p"
  if [ -z "$(want "$p" 3)" ]; then   # premium: inherit means the line is ABSENT, not empty
    grep -q '^model:' "$SK/agents/$p.md" && fail "$p must carry no model: line (premium inherits, ADR-0041)" || pass
  fi
done
# Monotonicity: the heat ladder must order the personas the way COST does. Duplicates are
# correct here (implementer/actuator are the same model tier, and planner/verifier are both
# premium at high effort, so each pair must look the same); what
# must never happen is a cheap persona reading hotter than an expensive one. This is the
# check that catches a well-meaning "let's make the actuator red" from re-tainting the
# scale with a second, contradictory meaning.
heat(){ case "$1" in cyan) echo 1 ;; green) echo 2 ;; yellow) echo 3 ;; red) echo 4 ;; *) echo 0 ;; esac; }
ladder_ok=1
for pair in "researcher<implementer" "implementer=actuator" "actuator<planner" "planner=verifier"; do
  a="${pair%%[<=]*}"; b="${pair##*[<=]}"; op="${pair//[a-z]/}"
  ha="$(heat "$(want "$a" 5)")"; hb="$(heat "$(want "$b" 5)")"
  case "$op" in
    '<') [ "$ha" -lt "$hb" ] || { ladder_ok=0; echo "  heat: $a ($ha) must be cooler than $b ($hb)" >&2; };;
    '=') [ "$ha" -eq "$hb" ] || { ladder_ok=0; echo "  heat: $a ($ha) and $b ($hb) are the same tier, must match" >&2; };;
  esac
done
[ "$ladder_ok" = 1 ] && pass || fail "color heat ladder must follow cost order"
# Negatives (disk-first read lane, ADR-0014): read-only personas carry a Write tool
# (write: results; findings/_quarantine for researcher, verdicts for verifier; the
# scope is prose in their briefs) so their results survive interruption. They must
# still NOT carry Edit (they create new result files, never edit source), and the
# actuator (writes live state via run, not source via Write) carries neither.
for p in researcher verifier; do
  if grep -qE '^tools: .*Edit' "$SK/agents/$p.md"; then fail "$p must not have Edit (results Write, no source edits)"; else pass; fi
done
if grep -qE '^tools: .*(Write|Edit)' "$SK/agents/actuator.md"; then fail "actuator must not have Write/Edit"; else pass; fi

# --- Hook groups: the contract declares two hooks, so hooks.json carries exactly two
#     groups (PreToolUse/Bash -> shared-checkout floor, SessionStart/compact -> reground).
assert_eq "$(grep -c '"matcher"' "$SK/hooks/hooks.json")" 2 "hooks.json has exactly two hook groups"
if grep -q '"matcher": "Bash"' "$SK/hooks/hooks.json" && grep -q '"matcher": "compact"' "$SK/hooks/hooks.json"; then pass; else fail "hooks.json matchers are Bash and compact"; fi

# --- Native worktree isolation: the implementer is dispatched into its own worktree.
if grep -q '^isolation: worktree' "$SK/agents/implementer.md"; then pass; else fail "implementer.md carries isolation: worktree"; fi
for p in researcher planner verifier actuator; do
  if grep -q '^isolation:' "$SK/agents/$p.md"; then fail "$p must not carry isolation"; else pass; fi
done

# --- cc_hooks_json with an empty watch class: no empty group, valid JSON (a contract
#     with only the shell hook, and one with no hooks at all).
if have_yq4; then
  LIBD="$(cd "$SK/../.." && pwd)/scripts/harness-lib"
  tmpc="$(mktemp -d)"
  yq 'del(.hooks.compaction_reground)' "$SK/skills/orchestrate/references/agents.yaml" > "$tmpc/shell-only.yaml"
  yq '.hooks = {}' "$SK/skills/orchestrate/references/agents.yaml" > "$tmpc/none.yaml"
  for c in shell-only none; do
    ( AGENTS="$tmpc/$c.yaml"; SKILL_DIR="$SK/skills/orchestrate"; . "$LIBD/common.sh"; . "$LIBD/claude-code.sh"
      cc_hooks_json "$tmpc/$c.json" '${CLAUDE_PLUGIN_ROOT}/h' )
    if yq -p=json -o=json '.' "$tmpc/$c.json" >/dev/null 2>&1; then pass; else fail "cc_hooks_json ($c) emits valid JSON"; fi
  done
  assert_eq "$(grep -c '"matcher"' "$tmpc/shell-only.json")" 1 "cc_hooks_json shell-only emits one group"
  assert_eq "$(grep -c '"matcher"' "$tmpc/none.json")" 0 "cc_hooks_json with no hooks emits no group"
  rm -rf "$tmpc"
else
  echo "(skip empty-class hooks.json: $YQ4_SKIP)"
fi

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

# --- Clarification binding (SKILL.md loop step 3, the front-door clarify): the router-prose config that binds
#     WHICH clarification skill fires must stay present and order-matched. Nothing
#     compiles it per-harness, so without this guard it can silently drift or vanish
#     (the gate would fall through to inline on every ambiguous goal, unnoticed). It
#     lives under conventions:, not top-level — a wrong path once read it as ABSENT.
if have_yq4; then
  AGY="$SK/skills/orchestrate/references/agents.yaml"
  got_cs="$(yq '.conventions.clarification_skills | join(",")' "$AGY" 2>/dev/null)"
  assert_eq "$got_cs" "grill-with-docs,grill-me,brainstorming,inline" "clarification_skills present + order-matched (loop step 3)"
else
  echo "(skip clarification binding: $YQ4_SKIP)"
fi

# --- Tier-table parity: SKILL.md's right-sizing table is prose the router reads; the
#     agents.yaml tier is what the harness binds. Each persona's row must be exactly
#     `| <persona> | <model> | <effort> |` and match cc_model(tier) and the effort, so
#     the brief never tells the router one horsepower while the agent file runs another.
#     cc_model premium emits nothing (no model: line), which the table spells `inherit`.
if have_yq4; then
  AGT="$SK/skills/orchestrate/references/agents.yaml"
  SKMD="$SK/skills/orchestrate/SKILL.md"
  . "$(cd "$SK/../.." && pwd)/scripts/harness-lib/claude-code.sh"   # function defs only
  for p in $(yq '.personas | keys | .[]' "$AGT"); do
    m="$(cc_model "$(yq ".personas.$p.tier.model" "$AGT")")"
    row="| $p | ${m:-inherit} | $(yq ".personas.$p.tier.effort" "$AGT") |"
    if grep -qxF "$row" "$SKMD"; then pass; else fail "tier-table row missing from SKILL.md: '$row'"; fi
  done
else
  echo "(skip tier-table parity: $YQ4_SKIP)"
fi

# --- Writer result-file contract survives compilation (0.9.4, the overnight-stall fix):
#     the compiled implementer and actuator briefs must carry the minted result path and
#     the completion sentinel, so the router can read writer completion from disk instead
#     of waiting on a chat handback the harness delivers at most once.
for p in implementer actuator; do
  grep -q 'results/<dispatch_id>\.md' "$SK/agents/$p.md" && pass || fail "$p compiled brief names the writer result path (results/<dispatch_id>.md)"
  grep -q 'orchestrate:complete' "$SK/agents/$p.md" && pass || fail "$p compiled brief carries the completion sentinel"
done
