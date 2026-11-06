# Tier 3c — COMPACTION = seamless handoff between router instances. When context is
# compacted, a NEW router instance must pick up exactly where the old one left off. The
# on-compaction.sh hook is that handoff: it replays the ledger (reground) and injects the
# reconstructed board as AUTHORITATIVE SessionStart context. This characterizes that
# payload deterministically (the hook's real firing on a live compaction is the
# interactive Issue-B limitation, documented separately; here we prove WHAT it hands off).
HOOK="$HERE/../skills/orchestrate/runtime/hooks/on-compaction.sh"
R="$HERE/../skills/orchestrate/runtime/ledger.sh"

# 1) an OPEN WRITER lane survives the handoff: the new instance is told to resume it
d="$(mktemp_repo)"; cd "$d"
bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"implementer","branch":"worktree-agent-T1-implementer"}'
out="$(bash "$HOOK" 2>&1)"
case "$out" in *AUTHORITATIVE*) pass;; *) fail "compaction injects an AUTHORITATIVE board for the new router";; esac
case "$out" in *"OPEN WRITER"*T1*) pass;; *) fail "compaction reconstructs the open writer lane (seamless handoff)";; esac
case "$out" in *"counted from disk"*) pass;; *) fail "handoff tells the new instance retry budgets are counted from disk, not memory";; esac
cd /; rm -rf "$d"

# 2) a CLEAN board hands off cleanly — framed for the new instance, no phantom lanes
d="$(mktemp_repo)"; cd "$d"
out="$(bash "$HOOK" 2>&1)"
case "$out" in *AUTHORITATIVE*) pass;; *) fail "clean board still frames the handoff";; esac
case "$out" in *"no open lanes"*) pass;; *) fail "clean board -> no open lanes injected";; esac
cd /; rm -rf "$d"

# 3) a DIRTY writer worktree (uncommitted work on a worktree-* branch) -> the handoff HALTs
#    the new instance instead of letting it dispatch past an unreconciled lane.
d="$(mktemp_repo)"; cd "$d"
git commit -qm init --allow-empty
git worktree add -q -b worktree-T9-implementer .agents/worktrees/T9 HEAD 2>/dev/null
echo x > .agents/worktrees/T9/work.txt
out="$(bash "$HOOK" 2>&1)"
case "$out" in *HALT*) pass;; *) fail "dirty writer worktree after compaction -> HALT injected (fail-closed handoff)";; esac
case "$out" in *"DIRTY WORKTREE"*) pass;; *) fail "HALT names the unreconciled worktree";; esac
cd /; rm -rf "$d"

# 4) the SessionStart contract: with jq present the payload is the required envelope
if command -v jq >/dev/null 2>&1; then
  d="$(mktemp_repo)"; cd "$d"
  out="$(bash "$HOOK" 2>/dev/null)"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext|length>0)' >/dev/null 2>&1 \
    && pass || fail "compaction emits the SessionStart additionalContext envelope CC requires"
  cd /; rm -rf "$d"
fi
