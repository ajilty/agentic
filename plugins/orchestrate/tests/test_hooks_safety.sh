RT="$HERE/../skills/orchestrate/runtime/hooks"
# Claude Code PreToolUse contract: ALLOW = exit 0 with NO stdout; DENY = exit 2
# (reason on stderr). Emitting decision JSON trips CC's hook-output validation, so
# allow paths must be stdout-silent. These tests lock that contract + the rule that
# a hook NEVER errors on missing env (the live failure that broke the session).

# --- deny-heldout-read.sh ---
o="$(PERSONA= HELDOUT_ROOT= bash "$RT/deny-heldout-read.sh" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "deny-heldout: exit 0 when unconfigured (no :? abort)"
assert_eq "$o" "" "deny-heldout: silent stdout on allow (no JSON to fail validation)"
PERSONA=verifier HELDOUT_ROOT=/tmp/ho RESOLVED_PATH=/tmp/ho/probe bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "deny-heldout: allows non-writers even under HELDOUT_ROOT"
PERSONA=implementer HELDOUT_ROOT=/tmp/ho RESOLVED_PATH=/tmp/ho/secret bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "deny-heldout: denies writer under HELDOUT_ROOT with exit 2"
PERSONA=implementer HELDOUT_ROOT=/tmp/ho RESOLVED_PATH= bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "deny-heldout: allows writer bash (empty path)"
PERSONA=actuator HELDOUT_ROOT=/tmp/ho RESOLVED_PATH=/tmp/ho/oracle bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "deny-heldout: denies the ACTUATOR under HELDOUT_ROOT too (agents.yaml applies_to)"

# --- keep-on-branch.sh ---
o="$(PERSONA= TOOL_INPUT='git checkout -b foo' bash "$RT/keep-on-branch.sh" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "keep-on-branch: exit 0 for non-implementer"
assert_eq "$o" "" "keep-on-branch: silent stdout on allow"
PERSONA=implementer TOOL_INPUT='git checkout -b foo' bash "$RT/keep-on-branch.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "keep-on-branch: denies implementer branch-create with exit 2"
PERSONA=implementer ASSIGNED_BRANCH= TOOL_INPUT='git commit -m x' bash "$RT/keep-on-branch.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "keep-on-branch: allows commit when no assigned branch"
# Off-branch commit check resolves the EFFECTIVE commit dir, not the hook's own cwd
# (live 2026-07-02 finding: under CC the hook cwd is the main checkout, so a bare
# rev-parse false-denied every legit `cd <worktree> && git commit`) — and not the
# assigned worktree's HEAD either (that is on the branch by construction; a vacuous
# check would let a main-checkout commit through).
r="$(mktemp_repo)"
( cd "$r" && git commit -qm init --allow-empty && git worktree add -q -b worktree-agent-T9-implementer .agents/worktrees/T9-implementer HEAD ) 2>/dev/null
( cd "$r" && PERSONA=implementer ASSIGNED_BRANCH=worktree-agent-T9-implementer TOOL_INPUT='cd .agents/worktrees/T9-implementer && git commit -m x' bash "$RT/keep-on-branch.sh" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "keep-on-branch: allows worktree commit via cd-compound (hook cwd = main checkout)"
( cd "$r" && PERSONA=implementer ASSIGNED_BRANCH=worktree-agent-T9-implementer TOOL_INPUT='git -C .agents/worktrees/T9-implementer commit -m x' bash "$RT/keep-on-branch.sh" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "keep-on-branch: allows worktree commit via git -C <worktree>"
( cd "$r" && PERSONA=implementer ASSIGNED_BRANCH=worktree-agent-T9-implementer TOOL_INPUT='git commit -m x' bash "$RT/keep-on-branch.sh" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "keep-on-branch: still denies a bare main-checkout commit off the assigned branch"
rm -rf "$r"

# --- gate-prod-apply.sh ---
o="$(PERSONA= bash "$RT/gate-prod-apply.sh" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "gate: exit 0 for non-actuator"
assert_eq "$o" "" "gate: silent stdout on allow"
PERSONA=actuator TICKET= PROD_TARGETS= bash "$RT/gate-prod-apply.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "gate: unregistered actuator (no ticket from env or record) is denied, with no :? abort"
PERSONA=actuator TICKET=T0 PROD_TARGETS= bash "$RT/gate-prod-apply.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "gate: registered actuator with no prod targets is allowed"

# --- write-scope.sh (planner spec/ADR write confinement; fail-closed) ---
o="$(PERSONA= bash "$RT/write-scope.sh" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "write-scope: exit 0 for non-planner"
assert_eq "$o" "" "write-scope: silent stdout on allow"
PERSONA=planner RESOLVED_PATH=docs/specs/2026-x.md bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "write-scope: allows planner write to docs/specs/**"
PERSONA=planner RESOLVED_PATH=docs/adr/0007-x.md bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "write-scope: allows planner write to docs/adr/**"
PERSONA=planner RESOLVED_PATH=.agents/runs/orchestrate/tickets/T1/spec.md bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "write-scope: allows planner write to the per-ticket artifact dir"
PERSONA=planner RESOLVED_PATH=/repo/docs/adr/0007-x.md bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "write-scope: allows absolute path under docs/adr/**"
PERSONA=planner RESOLVED_PATH=src/main.py bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "write-scope: denies planner write outside spec/ADR (exit 2)"
o="$(PERSONA=planner RESOLVED_PATH=src/main.py bash "$RT/write-scope.sh" 2>/dev/null)"
assert_eq "$o" "" "write-scope: empty stdout on DENY (stderr-only)"
PERSONA=planner RESOLVED_PATH= bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "write-scope: fail-closed on planner with unresolvable path (deny)"
PERSONA=implementer RESOLVED_PATH=src/main.py bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "write-scope: self-guards — only the planner is scoped (implementer allowed)"
PERSONA=planner RESOLVED_PATH='docs/specs/../../src/evil.py' bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "write-scope: denies path traversal (..) out of an allowed prefix"

# --- run-scope.sh (verifier tests-only: deny workspace/git-mutating Bash) ---
o="$(PERSONA= bash "$RT/run-scope.sh" 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "run-scope: exit 0 for non-verifier"
assert_eq "$o" "" "run-scope: silent stdout on allow"
PERSONA=verifier TOOL_INPUT='bash tests/run.sh' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: allows the verifier to run the test suite"
PERSONA=verifier TOOL_INPUT='pytest -q 2>&1' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: allows a test run with benign 2>&1 redirect"
PERSONA=verifier TOOL_INPUT='grep -rn foo src' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: allows read-only inspection (grep)"
PERSONA=verifier TOOL_INPUT='confirm and rearm' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: no false-positive on substrings (confirm/rearm not rm/mv)"
PERSONA=verifier TOOL_INPUT='git checkout -- .' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "run-scope: denies git working-tree mutation (exit 2)"
PERSONA=verifier TOOL_INPUT='echo pass > tests/result.txt' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "run-scope: denies output redirection to a file"
PERSONA=verifier TOOL_INPUT='sed -i s/x/y/ tests/t.py' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "run-scope: denies in-place edit (sed -i)"
PERSONA=verifier TOOL_INPUT='rm tests/t.py' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "run-scope: denies rm"
o="$(PERSONA=verifier TOOL_INPUT='rm tests/t.py' bash "$RT/run-scope.sh" 2>/dev/null)"
assert_eq "$o" "" "run-scope: empty stdout on DENY (stderr-only)"
PERSONA=implementer TOOL_INPUT='echo x > src/foo.py' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: self-guards — only the verifier is scoped (implementer writes freely)"
PERSONA=verifier TOOL_INPUT='git -C . checkout -- .' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "run-scope: denies git mutation with intervening -C option"
PERSONA=verifier TOOL_INPUT='git -C . reset --hard' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "run-scope: denies git reset --hard behind -C"
PERSONA=verifier TOOL_INPUT='git status' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: allows read-only git status (no over-denial)"
PERSONA=verifier TOOL_INPUT='git diff HEAD' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "run-scope: allows read-only git diff"

# --- stdin (Claude Code) path: identity + tool input arrive as stdin JSON ---
if command -v jq >/dev/null 2>&1; then
  printf '{"agent_type":"implementer","tool_name":"Read","tool_input":{"file_path":"/tmp/ho/secret"}}' \
    | HELDOUT_ROOT=/tmp/ho bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "deny-heldout: denies writer via stdin agent_type+file_path (CC path)"
  printf '{"agent_type":"verifier","tool_input":{"file_path":"/tmp/ho/probe"}}' \
    | HELDOUT_ROOT=/tmp/ho bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "deny-heldout: allows non-writer via stdin (CC path)"
  # A writer can read the held-out oracle through the SHELL (cat $HELDOUT_ROOT/x), which
  # carries no file_path — only tool_input.command. The hook must inspect the command too,
  # or the denial silently fails open on every Bash-capable writer (CC and Codex alike).
  printf '{"agent_type":"implementer","tool_name":"Bash","tool_input":{"command":"cat /tmp/ho/oracle.py"}}' \
    | HELDOUT_ROOT=/tmp/ho bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "deny-heldout: denies writer reading held-out via Bash command (not just file_path)"
  printf '{"agent_type":"implementer","tool_name":"Bash","tool_input":{"command":"ls -la && echo done"}}' \
    | HELDOUT_ROOT=/tmp/ho bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "deny-heldout: allows writer Bash that does not reference HELDOUT_ROOT"
  printf '{"agent_type":"implementer","tool_name":"Bash","tool_input":{"command":"git checkout -b x"}}' \
    | bash "$RT/keep-on-branch.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "keep-on-branch: denies implementer branch-create via stdin (CC path)"
  printf '{"tool_name":"Bash","tool_input":{"command":"git checkout -b x"}}' \
    | bash "$RT/keep-on-branch.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "keep-on-branch: allows main session (no agent_type) via stdin (CC path)"
  printf '{"agent_type":"actuator","tool_input":{"command":"terraform apply"}}' \
    | bash "$RT/gate-prod-apply.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "gate: detects actuator via stdin; unregistered (no record, no env) -> deny"
  printf '{"agent_type":"actuator","tool_input":{"command":"terraform apply"}}' \
    | TICKET=T0 bash "$RT/gate-prod-apply.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "gate: detects actuator via stdin; registered with no prod targets -> allow"
  printf '{"agent_type":"planner","tool_name":"Write","tool_input":{"file_path":"src/x.py"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "write-scope: denies planner write to src via stdin (CC path)"
  printf '{"agent_type":"planner","tool_name":"Write","tool_input":{"file_path":"docs/adr/0007-x.md"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "write-scope: allows planner docs/adr write via stdin (CC path)"
  # Codex apply_patch: paths live in the patch body (tool_input.command), not file_path.
  # The hook must parse them and confine each (ANY out-of-scope target denies the patch).
  printf '%s' '{"agent_type":"planner","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/x.py\n@@\n+x\n*** End Patch\n"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "write-scope: denies planner apply_patch write to src (Codex patch path)"
  printf '%s' '{"agent_type":"planner","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: docs/adr/0007-x.md\n@@\n+x\n*** End Patch\n"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "write-scope: allows planner apply_patch write to docs/adr (Codex patch path)"
  printf '%s' '{"agent_type":"planner","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: docs/adr/ok.md\n@@\n+a\n*** Add File: src/evil.py\n+b\n*** End Patch\n"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "write-scope: denies planner apply_patch when ANY target is out of scope (fail-closed)"
  # Tool-awareness (Codex shares one PreToolUse matcher across hooks): write-scope must
  # NOT confine non-write tools, or it would block a confined persona's reads/test-runs.
  printf '%s' '{"agent_type":"verifier","tool_name":"Read","tool_input":{"file_path":"src/foo.py"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "write-scope: allows a confined persona to READ source (not a write; Codex shared matcher)"
  printf '%s' '{"agent_type":"verifier","tool_name":"Bash","tool_input":{"command":"pytest -q"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "write-scope: ignores verifier Bash (run-scope governs that, not write-scope)"
  o="$(printf '{"agent_type":"planner","tool_input":{"file_path":"src/x.py"}}' | bash "$RT/write-scope.sh" 2>/dev/null)"
  assert_eq "$o" "" "write-scope: empty stdout on stdin DENY (stderr-only)"
  printf '{"agent_type":"verifier","tool_name":"Bash","tool_input":{"command":"rm tests/t.py"}}' \
    | bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "run-scope: denies verifier rm via stdin (CC path)"
  printf '{"agent_type":"verifier","tool_name":"Bash","tool_input":{"command":"bash tests/run.sh"}}' \
    | bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "run-scope: allows verifier test run via stdin (CC path)"
  # stdin DENY path is stderr-only: empty stdout even when it blocks (else "Invalid input")
  o="$(printf '{"agent_type":"implementer","tool_input":{"file_path":"/tmp/ho/x"}}' | HELDOUT_ROOT=/tmp/ho bash "$RT/deny-heldout-read.sh" 2>/dev/null)"
  assert_eq "$o" "" "deny-heldout: empty stdout on stdin DENY (stderr-only)"
  # stdin identity takes PRECEDENCE over env: agent_type=verifier beats PERSONA=implementer -> allow
  printf '{"agent_type":"verifier","tool_input":{"file_path":"/tmp/ho/x"}}' \
    | PERSONA=implementer HELDOUT_ROOT=/tmp/ho RESOLVED_PATH=/tmp/ho/x bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "deny-heldout: stdin agent_type overrides env PERSONA"
  # --- REGRESSION (caught by Tier 3b live eval): the CC plugin delivers a NAMESPACED
  #     agent_type, e.g. "orchestrate:actuator" — not the bare persona. Every
  #     persona-guarded hook must normalize the namespace, else the whole hook-enforced
  #     safety layer silently no-ops under the plugin. One per guarded hook:
  printf '{"agent_type":"orchestrate:implementer","tool_name":"Read","tool_input":{"file_path":"/tmp/ho/secret"}}' \
    | HELDOUT_ROOT=/tmp/ho bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "deny-heldout: denies plugin-namespaced orchestrate:implementer"
  printf '{"agent_type":"orchestrate:implementer","tool_name":"Bash","tool_input":{"command":"git checkout -b x"}}' \
    | bash "$RT/keep-on-branch.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "keep-on-branch: denies plugin-namespaced orchestrate:implementer branch-create"
  printf '{"agent_type":"orchestrate:planner","tool_name":"Write","tool_input":{"file_path":"src/x.py"}}' \
    | bash "$RT/write-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "write-scope: denies plugin-namespaced orchestrate:planner write to src"
  printf '{"agent_type":"orchestrate:verifier","tool_name":"Bash","tool_input":{"command":"rm tests/t.py"}}' \
    | bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "run-scope: denies plugin-namespaced orchestrate:verifier rm"
  gd="$(mktemp -d)"; mkdir -p "$gd/.agents/runs/orchestrate"
  printf '{"agent_type":"orchestrate:actuator","tool_input":{"command":"terraform apply"}}' \
    | ( cd "$gd" && TICKET=T1 PROD_TARGETS="tfstate:prod/db" bash "$RT/gate-prod-apply.sh" ) >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "2" "gate: denies plugin-namespaced orchestrate:actuator with unacked prod target"
  rm -rf "$gd"
else
  echo "(skip stdin/CC-path hook tests: jq absent)"
fi
# malformed JSON on stdin must degrade safely (no crash) — clean env -> allow
printf 'not json{' | bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "deny-heldout: malformed stdin JSON degrades to allow (no crash)"
# no hang on EOF stdin (the [ -t 0 ] guard) — bounded by timeout
if command -v timeout >/dev/null 2>&1; then
  timeout 5 bash "$RT/deny-heldout-read.sh" </dev/null >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "deny-heldout: no hang on EOF stdin (exit 0 within timeout)"
fi

# --- GENERALIZED session-safety floor: EVERY hook must exit 0 when fired with no
# orchestrate context env (the real "main router runs a tool" condition that broke
# the session). Auto-covers any hook added later. ---
d="$(mktemp_repo)"; cd "$d"
for h in "$RT"/*.sh; do
  name="$(basename "$h")"
  env -u PERSONA -u HELDOUT_ROOT -u ASSIGNED_BRANCH -u TICKET -u PROD_TARGETS \
      -u TOOL_INPUT -u RESOLVED_PATH -u CODEX_TOOL_PATH -u CODEX_TOOL_INPUT \
      -u CLAUDE_AGENT_TYPE -u CODEX_AGENT -u DISPATCH_ID \
      bash "$h" </dev/null >/dev/null 2>&1
  assert_eq "$?" "0" "hook $name exits 0 with no orchestrate env (session-safety floor)"
done
cd /; rm -rf "$d"

# --- guard-shared-checkout.sh: universal git-safety floor (ADR-0013). No working-tree/
#     history-discarding git on the PRIMARY shared checkout, for ANY persona incl. the
#     router (no agent_type). This is the data-loss stop (reset --hard ate an unpushed commit). ---
gco="$(mktemp_repo)"; cd "$gco"; git commit --allow-empty -q -m init 2>/dev/null
printf '{"tool_input":{"command":"git reset --hard origin/main"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "2" "shared-checkout: deny reset --hard on PRIMARY checkout (router/no persona)"
printf '{"agent_type":"orchestrate:implementer","tool_input":{"command":"git clean -fd"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "2" "shared-checkout: deny git clean -fd on PRIMARY (persona-independent)"
printf '{"tool_input":{"command":"git checkout -- ."}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "2" "shared-checkout: deny git checkout -- . on PRIMARY"
o="$(printf '{"tool_input":{"command":"git reset --hard X"}}' | bash "$RT/guard-shared-checkout.sh" 2>/dev/null)"
assert_eq "$o" "" "shared-checkout: empty stdout on DENY (stderr-only)"
printf '{"tool_input":{"command":"git fetch origin --prune"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "0" "shared-checkout: allow git fetch (the §9a base-correction) on PRIMARY"
printf '{"tool_input":{"command":"git worktree add -b wt /tmp/x origin/main"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "0" "shared-checkout: allow git worktree add (the §9a flow) on PRIMARY"
printf '{"tool_input":{"command":"git status"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "0" "shared-checkout: allow read-only git on PRIMARY (no over-denial)"
# regression (live 2026-07-06): a benign `checkout -b` compound must NOT false-deny because a
# `.`/`--`/`-f` token appears in ANOTHER statement (an unrelated path or a commit message).
printf '{"tool_input":{"command":"git checkout -b feat/x && git add a.b docs/adr && git commit -m \"fix -- do the thing. done\""}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "0" "shared-checkout: allow 'checkout -b' compound (tokens in other statements don't trip it)"
# but a REAL destructive checkout is still denied even when bundled into a compound
printf '{"tool_input":{"command":"git status && git checkout -- ."}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "2" "shared-checkout: still deny 'checkout -- .' even inside a compound"
printf '{"tool_input":{"command":"rm -rf build"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1
assert_eq "$?" "0" "shared-checkout: ignore non-git commands"
# linked worktree (writer's own sandbox): destructive ops are its business -> ALLOW
git worktree add -q -b wtX "$gco-wtX" HEAD 2>/dev/null
( cd "$gco-wtX" && printf '{"tool_input":{"command":"git reset --hard HEAD"}}' | bash "$RT/guard-shared-checkout.sh" >/dev/null 2>&1; exit $? )
assert_eq "$?" "0" "shared-checkout: allow reset --hard in a LINKED worktree (not the shared checkout)"
cd /; git -C "$gco" worktree remove --force "$gco-wtX" 2>/dev/null; rm -rf "$gco" "$gco-wtX"

# --- run-scope.sh scratch carve-out (ADR-0026): verifier rehearsal writes to throwaway
#     scratch roots are allowed; repo/git mutation stays sealed. ---
PERSONA=verifier TOOL_INPUT='echo done > /tmp/claude-x/sentinel.md' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "0" "run-scope: allow redirect to /tmp (rehearsal sentinel)"
PERSONA=verifier TOOL_INPUT='tee /var/tmp/stub/aws' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "0" "run-scope: allow tee into /var/tmp (stub binary)"
PERSONA=verifier TMPDIR=/scratchy TOOL_INPUT='printf x > /scratchy/probe.sh' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "0" "run-scope: allow redirect under \$TMPDIR"
PERSONA=verifier TOOL_INPUT='rm /tmp/rehearsal/f' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "0" "run-scope: allow rm confined to scratch"
PERSONA=verifier TOOL_INPUT='echo x > out.txt' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "2" "run-scope: still deny redirect to a repo-relative path"
PERSONA=verifier TOOL_INPUT='echo a > /tmp/a && echo b > b.txt' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "2" "run-scope: mixed targets deny (one non-scratch poisons the command)"
PERSONA=verifier TOOL_INPUT='sed -i s/a/b/ src/main.c' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "2" "run-scope: still deny sed -i on repo paths"
PERSONA=verifier TOOL_INPUT='rm -rf src' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "2" "run-scope: still deny relative-path rm (fail-closed: not provably scratch)"
PERSONA=verifier TOOL_INPUT='git -C /tmp/x commit -m y' bash "$RT/run-scope.sh" >/dev/null 2>&1
assert_eq "$?" "2" "run-scope: git mutation denied even under a scratch path"

# --- guard-merge-base.sh (ADR-0027): merges on the PRIMARY checkout must land on the
#     journaled integration base (goal event `base`); fail-open without one. ---
gmb="$(mktemp_repo)"; cd "$gmb"; git commit --allow-empty -q -m init
git checkout -q -b integration 2>/dev/null || git switch -q -c integration
L="$RT/../ledger.sh"
printf '{"tool_input":{"command":"git merge lane-x"}}' | bash "$RT/guard-merge-base.sh" >/dev/null 2>&1
assert_eq "$?" "0" "merge-base: fail-open when no goal/base journaled"
bash "$L" goal "ship it" "docs/spec.md" "integration" >/dev/null 2>&1
printf '{"tool_input":{"command":"git merge lane-x"}}' | bash "$RT/guard-merge-base.sh" >/dev/null 2>&1
assert_eq "$?" "0" "merge-base: allow merge when HEAD == journaled base"
git checkout -q -b bystander
printf '{"tool_input":{"command":"git merge lane-x"}}' | bash "$RT/guard-merge-base.sh" >/dev/null 2>&1
assert_eq "$?" "2" "merge-base: DENY merge when HEAD is a bystander branch (measured drift)"
o="$(printf '{"tool_input":{"command":"git merge lane-x"}}' | bash "$RT/guard-merge-base.sh" 2>/dev/null)"
assert_eq "$o" "" "merge-base: empty stdout on DENY (stderr-only)"
printf '{"tool_input":{"command":"git status"}}' | bash "$RT/guard-merge-base.sh" >/dev/null 2>&1
assert_eq "$?" "0" "merge-base: non-merge git untouched"
git worktree add -q -b wtM "$gmb-wtM" HEAD 2>/dev/null
( cd "$gmb-wtM" && printf '{"tool_input":{"command":"git merge lane-x"}}' | bash "$RT/guard-merge-base.sh" >/dev/null 2>&1; exit $? )
assert_eq "$?" "0" "merge-base: linked worktree exempt (writer's own sandbox)"
cd /; git -C "$gmb" worktree remove --force "$gmb-wtM" 2>/dev/null; rm -rf "$gmb" "$gmb-wtM"

# --- warn-agent-teams.sh: SessionStart advisory when Claude Code agent teams is on (ADR-0023).
#     Warn, never block; Claude-Code-only (silent no-op when the env var is unset). ---
o="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 bash "$RT/warn-agent-teams.sh" 2>&1)"; rc=$?
assert_eq "$rc" "0" "warn-agent-teams: exit 0 (advisory, never blocks)"
case "$o" in *"agent teams"*) pass;; *) fail "warn-agent-teams: warns when CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1";; esac
o2="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS= bash "$RT/warn-agent-teams.sh" 2>&1)"; rc2=$?
assert_eq "$rc2" "0" "warn-agent-teams: exit 0 when unset"
assert_eq "$o2" "" "warn-agent-teams: SILENT no-op when agent teams is off (Claude-only)"

# --- ADR-0032: every enforcement denial is journaled to the board as a `denied` event ---
d032="$(mktemp_repo)"; pushd "$d032" >/dev/null
B032=".agents/runs/orchestrate/board.jsonl"
: > "$B032"   # board exists -> denials journal
PERSONA=verifier TOOL_INPUT='git checkout -- src/app.py' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0032: run-scope still denies (exit 2) with journaling active"
grep -q '"event":"denied".*"hook":"run-scope".*"persona":"verifier"' "$B032" && pass || fail "ADR-0032: run-scope denial journaled (hook+persona)"
tail -1 "$B032" | grep -q '"ts":"20' && pass || fail "ADR-0032: denied event carries ts (via append)"
tail -1 "$B032" | grep -q 'git checkout' && pass || fail "ADR-0032: denied event notes the refused command"
n0="$(grep -c '"event":"denied"' "$B032")"
PERSONA=verifier TOOL_INPUT='bash tests/run.sh' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "ADR-0032: allow path still exits 0"
assert_eq "$(grep -c '"event":"denied"' "$B032")" "$n0" "ADR-0032: allow path journals NOTHING"
PERSONA=implementer HELDOUT_ROOT=/tmp/ho RESOLVED_PATH=/tmp/ho/secret bash "$RT/deny-heldout-read.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0032: deny-heldout still denies with journaling active"
grep -q '"event":"denied".*"hook":"deny-heldout-read".*"persona":"implementer"' "$B032" && pass || fail "ADR-0032: deny-heldout denial journaled"
popd >/dev/null; rm -rf "$d032"
# no board in cwd -> denial still fires, journaling silently skips (no stray board created)
d032b="$(mktemp -d)"; pushd "$d032b" >/dev/null
PERSONA=verifier TOOL_INPUT='git checkout -- x' bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0032: deny works without a board"
assert_no_file ".agents/runs/orchestrate/board.jsonl"
popd >/dev/null; rm -rf "$d032b"

# --- ADR-0035: run-scope mirrors the verifier's verdict-write allowance ---
V=".agents/runs/orchestrate/tickets/T9/verdicts"
PERSONA=verifier TOOL_INPUT="cat > $V/impl.v1.md" bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "ADR-0035: redirect INTO the verdicts path is allowed"
PERSONA=verifier TOOL_INPUT="mv /tmp/v.md $V/impl.v1.md" bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "ADR-0035: mv scratch -> verdicts is allowed"
PERSONA=verifier TOOL_INPUT="echo x > src/app.py" bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0035: redirect to source still denied"
PERSONA=verifier TOOL_INPUT="echo x > .agents/runs/orchestrate/tickets/T9/findings/f.md" bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0035: findings path is NOT the carve-out (verdicts only)"
PERSONA=verifier TOOL_INPUT="mv $V/impl.v1.md src/x.md" bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0035: mv OUT of verdicts into source still denied"
PERSONA=verifier TOOL_INPUT="git checkout -- $V/impl.v1.md" bash "$RT/run-scope.sh" >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "ADR-0035: git mutation stays denied even against the verdicts path"
