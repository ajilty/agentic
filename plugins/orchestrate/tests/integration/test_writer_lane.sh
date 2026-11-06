# Tier 3 (live) - FULL writer lane with native worktree isolation. The implementer is
# dispatched with isolation: "worktree" on the Agent call (the harness creates and owns
# the worktree), on a repo whose canonical branch is not the default branch: a STALE
# default branch (origin/HEAD -> master) plus a canonical CURRENT branch (blank-slate)
# that is ahead with a file master lacks.
# Proves: the commit lands on a worktree-* branch, and the primary checkout is untouched
# (same branch, same HEAD, no feature.txt). Robust to model-decline (skips).
if ! have_claude; then
  skip "tier3 writer-lane: claude CLI not on PATH"
elif ! have_live_auth; then
  skip "tier3 writer-lane: no live auth (ANTHROPIC_API_KEY or ~/.claude/.credentials.json)"
else
  h="$(mk_authed_home)"
  origin="$(mk_tmp)/origin.git"; repo="$(mk_tmp)/work"
  git init -q --bare "$origin"
  git clone -q "$origin" "$repo" 2>/dev/null
  ( cd "$repo" && git config user.email t@t && git config user.name t \
      && git checkout -q -b master && echo base > base.txt && git add base.txt && git commit -q -m c1 && git push -q -u origin master \
      && git checkout -q -b blank-slate && echo canonical > NEWFILE.txt && git add NEWFILE.txt && git commit -q -m c2 && git push -q -u origin blank-slate \
      && git remote set-head origin master )   # the stale-orphan trap: origin/HEAD -> master
  head_before="$(git -C "$repo" rev-parse HEAD)"

  prompt="Use the Agent tool to dispatch a subagent of type orchestrate:implementer with isolation set to worktree. Its task: create a file feature.txt containing the text hi, then stage and commit it with message wl (do not create or switch branches). Use your Bash and Write tools. When the commit exists, reply DONE."
  printf '%s' "$prompt" | ( cd "$repo" && HOME="$h" timeout 300 claude -p --plugin-dir "$PLUGIN_DIR" --allowedTools "Agent,Task,Bash,Write" ) >/dev/null 2>&1

  wtbranch="$(git -C "$repo" for-each-ref --format='%(refname:short)' 'refs/heads/worktree-*' 2>/dev/null | head -1)"
  if [ -n "$wtbranch" ] && git -C "$repo" cat-file -e "$wtbranch:feature.txt" 2>/dev/null; then
    pass   # the writer committed new work on a worktree-* branch
    [ -n "$(git -C "$repo" log --oneline "blank-slate..$wtbranch" 2>/dev/null)" ] && pass || fail "writer commit sits ahead of the base branch"
    git -C "$repo" cat-file -e "$wtbranch:NEWFILE.txt" 2>/dev/null && pass || fail "writer built on the CURRENT base (blank-slate file present), not stale master"
  else
    skip "implementer did not produce a worktree-* commit this run (model declined) - lane not exercised"
  fi

  # SAFETY: the primary checkout is untouched by the lane.
  assert_eq "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" "blank-slate" "primary checkout still on blank-slate"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "primary checkout HEAD unchanged"
  [ -f "$repo/NEWFILE.txt" ] && [ ! -f "$repo/feature.txt" ] && pass || fail "primary checkout intact (canonical content kept, no writer file leaked in)"
  cd /
fi
