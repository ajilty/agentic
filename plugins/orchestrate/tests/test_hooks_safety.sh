# Two hooks survive (ADR-0040): guard-shared-checkout.sh (PreToolUse Bash) and
# on-compaction.sh (SessionStart compact). Claude Code contract: ALLOW = exit 0 with NO
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

# (e) on-compaction.sh emits the SessionStart envelope
if command -v jq >/dev/null 2>&1; then
  d="$(mktemp_repo)"
  out="$(cd "$d" && bash "$RT/on-compaction.sh" 2>/dev/null)"; rc=$?
  assert_eq "$rc" "0" "on-compaction exits 0"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 && pass || fail "on-compaction emits hookEventName SessionStart"
  rm -rf "$d"
fi
