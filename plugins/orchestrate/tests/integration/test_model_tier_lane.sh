# Tier 3c (live): runtime proof that the compiled model tiers bind as ADR-0041 says.
# test_build asserts the compiled frontmatter (verifier: no model line, researcher: haiku);
# this proves CC runs each persona that way. The main loop is pinned to sonnet, so a
# verifier that inherits reports sonnet (an opus answer means a premium persona ran ABOVE
# the main loop, the ceiling ADR-0040 forbids), and a researcher reports haiku (its alias
# binds, differentiated from the verifier). Runs with CLAUDE_CODE_SUBAGENT_MODEL
# neutralized (it would otherwise override the frontmatter for every subagent).
# Model is self-reportable; effort is not, so effort stays a compile-time check.
if ! have_claude; then
  skip "tier3 model-tier: claude CLI not on PATH"
elif ! have_live_auth; then
  skip "tier3 model-tier: no live auth"
else
  h="$(mk_authed_home)"; repo="$(mk_repo)"
  report(){ # <persona> -> echoes the subagent's one-word model reply
    local persona="$1"
    local p="Use the Task tool to dispatch a subagent of type orchestrate:$persona with this exact instruction: 'Reply with ONLY the model family you are running on as one lowercase word: opus, sonnet, or haiku. Output just that one word, nothing else.' Do not pass a model on the call. Then output the subagent's reply verbatim."
    printf '%s' "$p" | ( cd "$repo" && HOME="$h" env -u CLAUDE_CODE_SUBAGENT_MODEL timeout 240 claude -p --model sonnet --plugin-dir "$PLUGIN_DIR" --allowedTools "Task" ) 2>&1
  }

  ov="$(report verifier)"
  case "$ov" in
    *sonnet*)       pass ;;                                    # premium inherits the main loop
    *opus*|*haiku*) fail "verifier did not inherit the sonnet main loop: $(printf '%s' "$ov" | tail -c 120)" ;;
    *)              skip "verifier model self-report inconclusive this run" ;;
  esac

  orr="$(report researcher)"
  case "$orr" in
    *haiku*)         pass ;;                                   # economy alias binds, below the main loop
    *opus*|*sonnet*) fail "researcher ran on the wrong model (want haiku): $(printf '%s' "$orr" | tail -c 120)" ;;
    *)               skip "researcher model self-report inconclusive this run" ;;
  esac
  cd /
fi
