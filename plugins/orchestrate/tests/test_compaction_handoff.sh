# Tier 3c: COMPACTION = seamless handoff between router instances. When context is
# compacted, a NEW router instance must pick up exactly where the old one left off. The
# on-compaction.sh hook is that handoff: it replays the ledger (reground) and injects the
# reconstructed board as AUTHORITATIVE SessionStart context. This characterizes that
# payload deterministically (the hook's real firing on a live compaction is the
# interactive Issue-B limitation, documented separately; here we prove WHAT it hands off).
HOOK="$HERE/../skills/orchestrate/runtime/hooks/on-compaction.sh"
R="$HERE/../skills/orchestrate/runtime/ledger.sh"

# 1) an OPEN WRITER lane survives the handoff: the new instance is told to resume it.
#    0.9.0 shape: native isolation, so dispatched carries no branch. In flight is not a HALT.
d="$(mktemp_repo)"; cd "$d"
git commit -qm init --allow-empty
bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"implementer","dispatch_id":"d1"}'
out="$(bash "$HOOK" 2>&1)"
case "$out" in *AUTHORITATIVE*) pass;; *) fail "compaction injects an AUTHORITATIVE board for the new router";; esac
case "$out" in *"OPEN WRITER"*T1*) pass;; *) fail "compaction reconstructs the open writer lane (seamless handoff)";; esac
case "$out" in *"counted from disk"*) pass;; *) fail "handoff tells the new instance retry budgets are counted from disk, not memory";; esac
case "$out" in *"commit subjects"*) pass;; *) fail "in-flight writer handed off with the re-dispatch check";; esac
case "$out" in *HALT*) fail "an in-flight writer with no branch must not inject HALT";; *) pass;; esac
cd /; rm -rf "$d"

# 2) a CLEAN board hands off cleanly: framed for the new instance, no phantom lanes
d="$(mktemp_repo)"; cd "$d"
bash "$R" goal "clean goal" >/dev/null
out="$(bash "$HOOK" 2>&1)"
case "$out" in *AUTHORITATIVE*) pass;; *) fail "clean board still frames the handoff";; esac
case "$out" in *"no open lanes"*) pass;; *) fail "clean board -> no open lanes injected";; esac
cd /; rm -rf "$d"

# 3) a lane worktree of this run (branch names a board ticket) holding uncommitted work
#    with NO dispatched row (the ledger lost it) -> the handoff HALTs the new instance.
d="$(mktemp_repo)"; cd "$d"
git commit -qm init --allow-empty
bash "$R" append '{"ticket":"T9","event":"intake","tier":"T1"}'
git worktree add -q -b worktree-T9-implementer .agents/worktrees/T9 HEAD 2>/dev/null
echo x > .agents/worktrees/T9/work.txt
out="$(bash "$HOOK" 2>&1)"
case "$out" in *HALT*) pass;; *) fail "lost-lane dirty worktree after compaction -> HALT injected (fail-closed handoff)";; esac
case "$out" in *"DIRTY WORKTREE"*T9*) pass;; *) fail "HALT names the unreconciled worktree";; esac
# 3a) the same dirty tree WITH a dispatched row is a writer in flight or crashed: reported, no HALT
bash "$R" append '{"ticket":"T9","event":"dispatched","persona":"implementer","dispatch_id":"d9"}'
out="$(bash "$HOOK" 2>&1)"
case "$out" in *"DIRTY WORKTREE"*"in flight or crashed"*) pass;; *) fail "dispatched lane's dirty tree reported as in flight ($out)";; esac
case "$out" in *HALT*) fail "a dispatched lane's dirty tree must not inject HALT";; *) pass;; esac
cd /; rm -rf "$d"

# 3c) no board at the git common root: the hook says nothing at all (non-orchestrate
#     sessions, non-code work); a non-git cwd likewise
d="$(mktemp -d)"; ( cd "$d" && git init -q )
out="$(cd "$d" && bash "$HOOK" 2>&1)"; rc=$?
assert_eq "$rc" "0" "no board: compaction hook exits 0"
assert_eq "$out" "" "no board: compaction hook prints nothing"
out="$(cd / && bash "$HOOK" 2>&1)"; rc=$?
assert_eq "$rc$out" "0" "non-git cwd: compaction hook exits 0 with no output"
rm -rf "$d"

# 3d) reground failing for any other reason is a distinct HALT, not the lost-lane one
d="$(mktemp_repo)"; cd "$d"; bash "$R" goal "g" >/dev/null
fk="$(mktemp -d)"; mkdir -p "$fk/hooks"; cp "$HOOK" "$fk/hooks/"; printf '#!/usr/bin/env bash\nexit 2\n' > "$fk/ledger.sh"
out="$(bash "$fk/hooks/on-compaction.sh" 2>&1)"
case "$out" in *"reground failed (exit 2)"*) pass;; *) fail "a failing reground is reported as a failure ($out)";; esac
cd /; rm -rf "$d" "$fk"

# 3b) a board too long for the 10,000-character additionalContext cap is trimmed: the
#     summary lines (GOAL, REGROUND) and the HALT survive
d="$(mktemp_repo)"; cd "$d"
git commit -qm init --allow-empty
for i in $(seq 1 400); do printf '{"ticket":"R%s","event":"dispatched","persona":"researcher","slug":"s%s"}\n' "$i" "$i"; done >> .agents/runs/orchestrate/board.jsonl
bash "$R" goal "long board goal" >/dev/null
bash "$R" append '{"ticket":"T8","event":"intake","tier":"T1"}'
git worktree add -q -b worktree-T8-implementer .agents/worktrees/T8 HEAD 2>/dev/null
echo x > .agents/worktrees/T8/work.txt
if command -v jq >/dev/null 2>&1; then
  ctx="$(bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')"
  [ "${#ctx}" -le 10000 ] && pass || fail "additionalContext stays under 10,000 characters (got ${#ctx})"
  case "$ctx" in *"lanes truncated"*) pass;; *) fail "truncation is marked";; esac
  case "$ctx" in *"GOAL: long board goal"*) pass;; *) fail "GOAL line survives truncation";; esac
  case "$ctx" in *"REGROUND: lane worktree"*) pass;; *) fail "REGROUND line survives truncation";; esac
  case "$ctx" in *"HALT: a lane worktree holds uncommitted work"*) pass;; *) fail "HALT survives truncation";; esac
  case "$ctx" in *"DIRTY WORKTREE"*T8*) pass;; *) fail "the dirty writer worktree line is kept ahead of read-only lanes";; esac
fi
cd /; rm -rf "$d"

# 4) the SessionStart contract: with jq present the payload is the required envelope
if command -v jq >/dev/null 2>&1; then
  d="$(mktemp_repo)"; cd "$d"; bash "$R" goal "g" >/dev/null
  out="$(bash "$HOOK" 2>/dev/null)"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext|length>0)' >/dev/null 2>&1 \
    && pass || fail "compaction emits the SessionStart additionalContext envelope CC requires"
  cd /; rm -rf "$d"
fi
