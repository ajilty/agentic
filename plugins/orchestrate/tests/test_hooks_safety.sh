# Three hooks: guard-shared-checkout.sh (PreToolUse Bash) and on-compaction.sh
# (SessionStart compact) survive ADR-0040; check-status-page.sh (PreToolUse Artifact)
# is added by ADR-0042. Claude Code contract: ALLOW = exit 0 with NO
# stdout; DENY = exit 2 with the reason on stderr. A hook NEVER errors on missing input.
RT="$HERE/../skills/orchestrate/runtime/hooks"
G="$RT/guard-shared-checkout.sh"
r="$(mktemp_repo)"
( cd "$r" && git commit -qm init --allow-empty && git worktree add -q -b wt-lane .agents/worktrees/lane HEAD ) 2>/dev/null
wt="$r/.agents/worktrees/lane"
feed(){ printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2" | bash "$G"; }

# (a) payload cwd is a linked worktree: a destructive op is that sandbox's own business
feed 'git reset --hard origin/main' "$wt" >/dev/null 2>&1; assert_eq "$?" "0" "linked-worktree cwd allows reset --hard (no cd in command)"
# (b) payload cwd is the primary checkout: denied, stdout empty
o="$(feed 'git reset --hard origin/main' "$r" 2>/dev/null)"; rc=$?
assert_eq "$rc" "2" "primary cwd denies reset --hard"
assert_eq "$o" "" "deny path keeps stdout empty (reason on stderr only)"
# the process cwd must NOT decide: the payload cwd does
( cd "$wt" && feed 'git reset --hard X' "$r" >/dev/null 2>&1 ); assert_eq "$?" "2" "payload cwd (primary) wins over process cwd (worktree)"
( cd "$r" && feed 'git reset --hard X' "$wt" >/dev/null 2>&1 ); assert_eq "$?" "0" "payload cwd (worktree) wins over process cwd (primary)"
# (b2) the target checkout is resolved per statement, not from the payload cwd alone:
#      from a linked-worktree cwd, `git -C <primary>` and `cd <primary> &&` hit the primary
feed "git -C $r reset --hard origin/main" "$wt" >/dev/null 2>&1; assert_eq "$?" "2" "worktree cwd + git -C <primary> reset --hard denied"
feed "cd $r && git reset --hard origin/main" "$wt" >/dev/null 2>&1; assert_eq "$?" "2" "worktree cwd + cd <primary> && reset --hard denied"
feed "cd $r; git clean -fd" "$wt" >/dev/null 2>&1; assert_eq "$?" "2" "worktree cwd + cd <primary>; clean -fd denied"
feed "git -C .agents/worktrees/lane reset --hard X" "$r" >/dev/null 2>&1; assert_eq "$?" "0" "primary cwd + git -C <relative worktree> reset --hard allowed"
feed "cd .agents/worktrees/lane && git reset --hard X" "$r" >/dev/null 2>&1; assert_eq "$?" "0" "primary cwd + cd <relative worktree> && reset --hard allowed"
feed "(cd $wt && git status) && git reset --hard X" "$r" >/dev/null 2>&1; assert_eq "$?" "2" "a subshell cd does not carry past its closing paren"
feed "cd $r && git status && git checkout -b y" "$wt" >/dev/null 2>&1; assert_eq "$?" "0" "cd <primary> with no destructive verb allowed"
# a payload cwd that does not exist falls back to the process cwd instead of failing open
( cd "$r" && feed 'git reset --hard X' "/nonexistent/orchestrate-$$" >/dev/null 2>&1 ); assert_eq "$?" "2" "nonexistent payload cwd falls back to process cwd (primary -> denied)"
# (c) no destructive verb: checkout -b plus commit is allowed on the primary (2026-07-06 regression)
feed 'git checkout -b x && git commit -m m' "$r" >/dev/null 2>&1; assert_eq "$?" "0" "checkout -b && commit allowed on primary"
feed 'git status && git checkout -- .' "$r" >/dev/null 2>&1; assert_eq "$?" "2" "checkout -- . still denied on primary in a compound line"
feed 'git clean -fd' "$r" >/dev/null 2>&1; assert_eq "$?" "2" "clean -fd denied on primary"
feed 'git fetch origin --prune' "$r" >/dev/null 2>&1; assert_eq "$?" "0" "fetch allowed"
feed 'rm -rf build' "$r" >/dev/null 2>&1; assert_eq "$?" "0" "non-git command ignored"
# (d) no stdin, no env: never errors
bash "$G" </dev/null >/dev/null 2>&1; assert_eq "$?" "0" "no stdin, no env -> exit 0"
# no cwd in the payload falls back to the process cwd
( cd "$r" && printf '{"tool_input":{"command":"git reset --hard X"}}' | bash "$G" >/dev/null 2>&1 ); assert_eq "$?" "2" "missing payload cwd falls back to process cwd"

# ADR-0032: a denial is journaled as a `denied` event; an allow journals nothing
B="$r/.agents/runs/orchestrate/board.jsonl"; : > "$B"
feed 'git reset --hard X' "$r" >/dev/null 2>&1
grep -q '"event":"denied".*"hook":"guard-shared-checkout"' "$B" && pass || fail "denial journaled to the board"
tail -1 "$B" | grep -q '"ts":"20' && pass || fail "denied event carries ts"
n0="$(grep -c '"event":"denied"' "$B")"
feed 'git status' "$r" >/dev/null 2>&1
assert_eq "$(grep -c '"event":"denied"' "$B")" "$n0" "allow path journals nothing"
d0="$(mktemp -d)"; ( cd "$d0" && git init -q ); feed 'git reset --hard X' "$d0" >/dev/null 2>&1; assert_eq "$?" "2" "deny works without a board"
assert_no_file "$d0/.agents/runs/orchestrate/board.jsonl"
rm -rf "$d0" "$r"

# (d2) the verb and directory shapes the floor covers (a primary whose path has a space,
#      so quoting matters). Payloads are built with jq so any command text survives.
if command -v jq >/dev/null 2>&1; then
  base="$(mktemp -d)"; P="$base/my repo"; mkdir -p "$P"
  ( cd "$P" && git init -q && git config user.email t@t && git config user.name t && git commit -qm init --allow-empty && git worktree add -q -b wt-s "$base/wt" HEAD ) 2>/dev/null
  W="$base/wt"; Q="\"$P\""
  fj(){ jq -cn --arg c "$1" --arg d "$2" '{tool_input:{command:$c},cwd:$d,agent_type:"orchestrate:implementer"}' | bash "$G" >/dev/null 2>&1; echo $?; }
  deny(){ assert_eq "$(fj "$1" "$2")" "2" "deny: $3"; }
  allow(){ assert_eq "$(fj "$1" "$2")" "0" "allow: $3"; }
  deny  "git -C $Q clean -df"                 "$W" "clean -df on the primary"
  deny  "git -C $Q clean -xdf"                "$W" "clean -xdf on the primary"
  deny  "git -C $Q clean --force -d"          "$W" "clean --force on the primary"
  deny  "git -C $Q switch --force main"       "$W" "switch --force on the primary"
  deny  "git -C $Q switch -f main"            "$W" "switch -f on the primary"
  deny  "git -C $Q checkout -qf main"         "$W" "checkout -qf on the primary"
  deny  "git -C $Q checkout --force main"     "$W" "checkout --force on the primary"
  deny  "git -C $Q checkout ."                "$W" "checkout . on the primary"
  deny  "git reset --hard>/dev/null"          "$P" "reset --hard with a glued redirect"
  deny  "git reset --hard >/dev/null 2>&1"    "$P" "reset --hard with redirects"
  deny  "cd -- $Q && git reset --hard"        "$W" "cd -- DIR"
  deny  "cd -P $Q && git reset --hard"        "$W" "cd -P DIR"
  deny  "pushd $Q && git reset --hard"        "$W" "pushd DIR"
  deny  "cd '$P' && git reset --hard"         "$W" "single-quoted DIR with a space"
  deny  "cd $Q && git reset --hard"           "$W" "double-quoted DIR with a space"
  deny  "git -C '$P' reset --hard"            "$W" "git -C single-quoted DIR with a space"
  deny  "cd .. && cd 'my repo' && git reset --hard" "$W" "relative cd chain into a spaced DIR"
  deny  "cd $Q
git reset --hard"                             "$W" "multi-line: cd, newline, reset"
  deny  "# discard local edits
git checkout -- ."                            "$P" "multi-line: a comment line first"
  deny  "PRIM=x; cd \"\$PRIM\" && git reset --hard" "$W" "unresolvable: cd to a variable"
  deny  "cd \$(git worktree list --porcelain | head -1 | cut -d' ' -f2) && git reset --hard" "$W" "unresolvable: cd to a command substitution"
  deny  "for d in x; do git -C \$d reset --hard; done" "$W" "unresolvable: git -C a variable"
  deny  "cd /nonexistent-orchestrate-$$; git reset --hard" "$P" "unresolvable: a cd that fails leaves the shell in the primary"
  deny  "popd; git reset --hard"              "$W" "unresolvable: popd with no pushd"
  deny  "pushd \"$W\" && popd && git reset --hard" "$P" "popd returns to the primary"
  deny  "nice git reset --hard"               "$P" "wrapper: nice"
  deny  "nice -n 5 git -C $Q reset --hard"    "$W" "wrapper: nice -n N"
  deny  "env -i git -C $Q clean -fdx"         "$W" "wrapper: env -i"
  deny  "env FOO=1 git -C $Q clean -fdx"      "$W" "wrapper: env VAR=val"
  deny  "sudo -u root git -C $Q reset --hard" "$W" "wrapper: sudo with an option argument"
  deny  "command git -C $Q reset --hard"      "$W" "wrapper: command"
  deny  "exec git -C $Q reset --hard"         "$W" "wrapper: exec"
  deny  "time git -C $Q reset --hard"         "$W" "wrapper: time"
  deny  "/usr/bin/git -C $Q checkout -f ."    "$W" "absolute path to git"
  allow "nice git reset --hard"               "$W" "wrapper in a linked worktree"
  allow "mkdir -p d && cd d && git clean -fdx" "$W" "cd to a not-yet-existing dir under a worktree"
  deny  "mkdir -p d && cd d && git clean -fdx" "$P" "cd to a not-yet-existing dir under the primary"
  allow "git reset --hard"                    "$W" "reset --hard inside a linked worktree"
  allow "git clean -fdx"                      "$W" "clean -fdx inside a linked worktree"
  allow "pushd \"$W\" && git clean -fd"       "$P" "pushd into the worktree"
  allow "cd -- \"$W\" && git checkout -- ."   "$P" "cd -- into the worktree"
  allow "git -C \"$W\" reset --hard"          "$P" "git -C the worktree"
  allow "git commit -m 'git reset --hard was wrong'" "$P" "a destructive phrase inside a quoted message"
  allow "git commit -F - <<'EOF'
fix: x
git reset --hard origin/main
git checkout -- .
EOF
git log -1"                                   "$P" "a destructive phrase inside a heredoc body"
  allow "echo git reset --hard"               "$P" "git words as another command's arguments"
  allow "ls # git reset --hard"               "$P" "a destructive phrase in a trailing comment"
  allow "git checkout -b fix-foo"             "$P" "checkout -b with an f in the branch name"
  allow "git clean -n"                        "$P" "clean dry run"
  allow "git switch -c feat"                  "$P" "switch -c"
  allow "cd \"\$X\" && git status"            "$P" "unresolvable dir with no destructive verb"
  # the persona that tripped the floor comes from the payload's agent_type
  mkdir -p "$P/.agents/runs/orchestrate"; : > "$P/.agents/runs/orchestrate/board.jsonl"
  fj "git reset --hard" "$P" >/dev/null
  grep -q '"persona":"orchestrate:implementer"' "$P/.agents/runs/orchestrate/board.jsonl" && pass || fail "denied row carries the payload's agent_type as persona"
  # no jq: any destructive verb in the raw payload is refused, everything else allowed
  noj="$(mktemp -d)"
  for b in bash git cat grep tr dirname head sed awk printf mkdir date; do bp="$(command -v "$b")"; [ -n "$bp" ] && ln -s "$bp" "$noj/$b"; done
  r="$(printf '{"tool_input":{"command":"git reset --hard"},"cwd":"%s"}' "$W" | PATH="$noj" bash "$G" >/dev/null 2>&1; echo $?)"
  assert_eq "$r" "2" "no jq: a destructive verb is refused (fail closed)"
  r="$(printf '{"tool_input":{"command":"git status"},"cwd":"%s"}' "$P" | PATH="$noj" bash "$G" >/dev/null 2>&1; echo $?)"
  assert_eq "$r" "0" "no jq: a non-destructive command is allowed"
  # macOS bash 3.2 runs the floor
  if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]' 2>/dev/null; then
    r="$(jq -cn --arg c "cd -- $Q && git reset --hard" --arg d "$W" '{tool_input:{command:$c},cwd:$d}' | /bin/bash "$G" >/dev/null 2>&1; echo $?)"
    assert_eq "$r" "2" "bash 3.2: the floor denies a quoted cd into the primary"
    r="$(jq -cn --arg c "git reset --hard" --arg d "$W" '{tool_input:{command:$c},cwd:$d}' | /bin/bash "$G" >/dev/null 2>&1; echo $?)"
    assert_eq "$r" "0" "bash 3.2: the floor allows a worktree reset"
  fi
  rm -rf "$base" "$noj"
else
  echo "(skip floor shape tests: jq absent)"
fi

# (e) on-compaction.sh emits the SessionStart envelope
if command -v jq >/dev/null 2>&1; then
  d="$(mktemp_repo)"; ( cd "$d" && bash "$RT/../ledger.sh" goal "g" >/dev/null )
  out="$(cd "$d" && bash "$RT/on-compaction.sh" 2>/dev/null)"; rc=$?
  assert_eq "$rc" "0" "on-compaction exits 0"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && pass || fail "on-compaction emits hookEventName SessionStart"
  rm -rf "$d"
fi

# --- check-status-page.sh (ADR-0042): a publish of the run's canonical page is checked
#     against the journal; everything else is none of its business.
C="$RT/check-status-page.sh"; FX="$HERE/fixtures/status-page"
pr="$(mktemp_repo)"; cp "$FX/board.jsonl" "$pr/.agents/runs/orchestrate/board.jsonl"
cp "$FX/status.html" "$pr/.agents/runs/orchestrate/status.html"
pub(){ # <json tool_input> <cwd> [now]
  printf '{"tool_name":"Artifact","tool_input":%s,"cwd":"%s"}' "$1" "$2" | PAGE_CHECK_NOW="${3:-2026-11-08T16:15:00Z}" bash "$C"; }
PGP="$pr/.agents/runs/orchestrate/status.html"
if command -v jq >/dev/null 2>&1; then
  o="$(pub "{\"file_path\":\"$PGP\"}" "$pr" 2>&1)"; assert_eq "$?" 0 "a page that agrees with the journal is published ($o)"
  assert_eq "$o" "" "allow path is silent"
  o="$(pub '{"file_path":".agents/runs/orchestrate/status.html"}' "$pr" 2>&1)"; assert_eq "$?" 0 "a relative path resolves against the payload cwd"
  echo '{"ticket":"runner-trust","event":"done"}' >> "$pr/.agents/runs/orchestrate/board.jsonl"
  o="$(pub "{\"file_path\":\"$PGP\"}" "$pr" 2>/dev/null)"; rc=$?
  assert_eq "$rc" 2 "a page that contradicts the journal is refused"
  assert_eq "$o" "" "deny path keeps stdout empty (reasons on stderr only)"
  e="$(pub "{\"file_path\":\"$PGP\"}" "$pr" 2>&1 >/dev/null)"
  case "$e" in *"was not published"*"records runner-trust as done"*"Rebuild every field"*) pass;; *) fail "the refusal names each failure and what to do ($e)";; esac
  o="$(pub "{\"file_path\":\"$PGP\"}" "$pr" 2026-11-09T09:00:00Z 2>&1 >/dev/null)"
  case "$o" in *"not the publish time"*) pass;; *) fail "a stale stamp at publish is named ($o)";; esac
  pub "{\"action\":\"read\",\"url\":\"https://example.invalid/a\"}" "$pr" >/dev/null 2>&1; assert_eq "$?" 0 "a read is not a publish"
  pub "{\"action\":\"list\"}" "$pr" >/dev/null 2>&1; assert_eq "$?" 0 "a list is not a publish"
  pub "{\"file_path\":\"$pr/notes.html\"}" "$pr" >/dev/null 2>&1; assert_eq "$?" 0 "another page is none of its business"
  pub "{\"file_path\":\"$PGP\",\"asset\":true,\"url\":\"https://example.invalid/a\"}" "$pr" >/dev/null 2>&1; assert_eq "$?" 0 "an asset upload is not a page publish"
fi
printf '' | bash "$C" >/dev/null 2>&1; assert_eq "$?" 0 "empty input is allowed, never an error"
printf 'not json' | bash "$C" >/dev/null 2>&1; assert_eq "$?" 0 "unparseable input is allowed, never an error"
