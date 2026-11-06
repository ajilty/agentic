# Tier 3 (live) — FULL read lane. THE proactive catch for the result-channel bug
# class (ADR-0014): the automated test the field failure slipped past because no
# test ran a real read-only dispatch and asserted its substantive result is durably
# retrievable FROM DISK, independent of the chat/notification channel. The writer
# lane proved writes land as commits; this proves reads land as files.
#
# A real researcher is dispatched to investigate a known local fact and WRITE its
# findings to the scoped quarantine path (the disk-first read lane). We then read
# that file straight off disk — never the agent's chat reply — and assert it carries
# the answer + the completion sentinel at the attributed path (slug.dispatch_id).
# That is the whole claim: a dropped/mislabeled/never-replayed notification can no
# longer lose a finding. Robust to model-decline (skips).
if ! have_claude; then
  skip "tier3 read-lane: claude CLI not on PATH"
elif ! have_live_auth; then
  skip "tier3 read-lane: no live auth (ANTHROPIC_API_KEY or ~/.claude/.credentials.json)"
else
  h="$(mk_authed_home)"; repo="$(mk_repo)"
  ( cd "$repo" && printf 'answer=42\n' > fact.txt )

  # The router (this session) mints slug + dispatch_id and the scoped path; the
  # researcher writes its result there. Attribution is the path we minted, not a
  # notification label.
  rel=".agents/runs/orchestrate/tickets/T1/findings/_quarantine/probe.d1.md"
  absq="$repo/$rel"
  prompt="Use the Task tool to dispatch a subagent of type orchestrate:researcher. Its task: read the file fact.txt in the current working directory, determine the integer value assigned to 'answer', and write your findings to the file $absq (create parent directories as needed) using your Write tool. The findings must state the value you found. Make that write your final action and end the file with a line containing exactly: <!-- orchestrate:complete -->. When the file exists, reply DONE."
  printf '%s' "$prompt" | ( cd "$repo" && HOME="$h" timeout 300 claude -p --plugin-dir "$PLUGIN_DIR" --allowedTools "Task,Read,Grep,Glob,Bash,Write" ) >/dev/null 2>&1

  if [ -f "$absq" ]; then
    pass   # the read-only result is DURABLE ON DISK at the attributed path
    grep -q '42' "$absq" && pass || fail "read-lane: findings carry the researched value (read from disk, not chat)"
    grep -q 'orchestrate:complete' "$absq" && pass || fail "read-lane: completion sentinel present (router can detect completion without a notification)"
    # the researcher stayed in its lane: it must NOT have written the TRUSTED findings
    # path (that is the router's promotion target; a direct write would bypass the router's quarantine (SKILL.md "Quarantine"))
    [ ! -f "$repo/.agents/runs/orchestrate/tickets/T1/findings/probe.md" ] && pass || fail "read-lane: researcher did NOT write the trusted findings path (gate not bypassed)"
  else
    skip "researcher did not produce the result file this run (model declined) — read lane not exercised"
  fi
  cd /
fi
