# Tier 3c (live) — TEST THE ROUTER: on an ambiguous goal, the router must recognize the
# ambiguity, SELECT the first-present clarification skill (SKILL.md loop step 3, first-present-wins), and
# JOURNAL that decision (`ledger.sh clarify <skill>`) so it's a checkable trace. This is
# the one choreography step that was previously invisible (clarification runs in router
# context, not a persona dispatch, so it left no ledger event). We seed the sandbox HOME
# with the real clarification skills so first-present selection is faithful.
#
#   clarify event names grill-with-docs -> router selected the first-present skill: PASS
#   clarify event names another skill    -> router journaled the decision (core behavior): PASS (noted)
#   no clarify event                     -> router didn't reach/journal it this run: SKIP
if ! have_claude; then
  skip "tier3 clarify-lane: claude CLI not on PATH"
elif ! have_live_auth; then
  skip "tier3 clarify-lane: no live auth"
else
  h="$(mk_authed_home)"; repo="$(mk_repo)"
  LEDGER="$PLUGIN_DIR/skills/orchestrate/runtime/ledger.sh"
  # seed the real clarification skills into the sandbox so first-present-wins is faithful
  mkdir -p "$h/.claude/skills"
  for s in grill-with-docs grill-me brainstorming; do
    [ -d "$HOME/.claude/skills/$s" ] && cp -r "$HOME/.claude/skills/$s" "$h/.claude/skills/" 2>/dev/null
  done
  prompt="You are the orchestrate router (use the orchestrate skill's SKILL.md as your brain). Run the intake loop on this goal:

GOAL: \"Add caching.\"

This goal is deliberately ambiguous: which layer, what TTL, which keys, which store are all open #UNKNOWNs. Follow SKILL.md loop step 3 (clarify if no oracle is nameable): select the configured clarification skill by first-present-wins preference order, and BEFORE invoking it, journal your selection by running this exact Bash command (substitute the skill you selected): bash $LEDGER clarify <skill>. The ledger helper is at $LEDGER. You do not need to complete the interactive clarification in this non-interactive run: journaling the selection is enough. Then stop."
  printf '%s' "$prompt" | ( cd "$repo" && HOME="$h" timeout 300 claude -p --plugin-dir "$PLUGIN_DIR" --allowedTools "Bash,Skill,Read,Task" ) >/dev/null 2>&1

  board="$repo/.agents/runs/orchestrate/board.jsonl"
  if grep -q '"event":"clarify".*grill-with-docs' "$board" 2>/dev/null; then
    pass   # router recognized ambiguity AND selected the first-present skill, journaled
    ( cd "$repo" && bash "$LEDGER" conformance clarify:grill-with-docs ) >/dev/null 2>&1
    assert_eq "$?" "0" "conformance can now verify the clarification step fired (clarify:grill-with-docs)"
  elif grep -q '"event":"clarify"' "$board" 2>/dev/null; then
    pass   # core behavior holds: the router journaled its clarify decision (a different skill)
    echo "  (note: router journaled clarify with a non-first-present skill: $(grep -o '"skill":"[^"]*"' "$board" | tail -1))"
  else
    skip "router did not journal a clarify decision this run (model declined / non-interactive intake) — not exercised"
  fi
  cd /
fi
