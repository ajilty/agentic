# The router's core instructions must always be in context (0.9.7, ADR-0043). Measured
# failures behind each check: a start command that only TOLD the router to load its
# instructions (loaded 1 of 14 at low effort, 12 of 14 at high); a compaction that keeps
# at most the first 5,000 tokens of a skill, or none; a recovery hook that asked for a
# reload (20 compactions, 3 reloads). So the core is short, printed by one command, and
# delivered three ways.
SK="$(cd "$HERE/.." && pwd)"; SD="$SK/skills/orchestrate"; R="$SD/runtime/ledger.sh"
core="$(bash "$R" core)"; assert_eq "$?" 0 "ledger.sh core prints"

# 1) Size: under the hook output cap with room for the hook's own header, and far under
#    the 5,000-token re-attach limit (about 3.5 characters a token).
n="$(printf '%s' "$core" | wc -c | tr -d ' ')"
[ "$n" -le 9500 ] && pass || fail "core is $n characters; the post-compaction hook can carry 9,500"
w="$(wc -c < "$SD/SKILL.md" | tr -d ' ')"
[ "$w" -le 16000 ] && pass || fail "SKILL.md is $w characters; a compaction re-attaches only its first 5,000 tokens"

# 2) Content: no frontmatter, the whole loop, the journal rule, the helper-on-PATH line,
#    and the absolute path the references are read from.
case "$core" in "---"*) fail "core carries frontmatter";; *) pass;; esac
for m in '1. **Reground.**' '2. **Intake and goal.**' '3. **Clarify' '4. **Right-size.**' '5. **Drive lanes.**' '6. **Verify**' '7. **Land**' '8. **Feedback.**' \
         'Never end a turn with a dispatch' 'Journal only canonical events' 'fresh `dispatch_id`' 'T2: the full chain' 'orchestrate:complete' 'are on your PATH' 'again after a compaction' "$SD/references/"; do
  case "$core" in *"$m"*) pass;; *) fail "core carries: $m";; esac
done

# 3) Pointers resolve, and nothing is orphaned: every reference the core names exists,
#    and every router reference is named by the core.
for f in $(grep -oE 'references/[a-z-]+\.(md|yaml)' "$SD/SKILL.md" | sort -u); do
  [ -f "$SD/$f" ] && pass || fail "core names $f, which does not exist"
done
for f in "$SD"/references/*.md; do
  b="$(basename "$f")"; grep -qF "$b" "$SD/SKILL.md" && pass || fail "reference $b is not named in the core, so nothing leads to it"
done
grep -q 'Point at the craft' "$SD/references/dispatching.md" && fail "dispatching still tells the router to point at the craft (personas carry it now)" || pass

# 4) Delivery one: the start command injects the core and pre-approves exactly that command.
I="$SK/commands/init.md"
grep -qF '!`${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh brief`' "$I" && pass || fail "init.md injects the brief (core plus every-run references)"
grep -qF 'allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh brief)' "$I" && pass || fail "init.md pre-approves the injected command"
assert_eq "$(awk 'f==2{print} /^---[[:space:]]*$/{f++}' "$I" | grep -c 'ledger.sh brief')" 1 "the injection survives the installers' frontmatter split (no --- rule in the body)"
br="$(bash "$SK/bin/ledger.sh" brief)"; assert_eq "$?" 0 "the bin shim the command calls prints the brief"
for m in '5. **Drive lanes.**' '# Right-sizing and context economy' '# Dispatching' '# Routing and quarantine' '| **T0** |' 'DECISION_FORK:'; do
  case "$br" in *"$m"*) pass;; *) fail "the brief carries: $m";; esac
done

# 5) Delivery two: the post-compaction hook prints the core itself, only where a board is.
H="$SD/runtime/hooks/reinject-core.sh"
nb="$(mktemp_repo)"; rm -rf "$nb/.agents"
o="$(cd "$nb" && bash "$H" 2>&1)"; assert_eq "$o" "" "no board: the hook prints nothing"
wb="$(mktemp_repo)"; ( cd "$wb" && git commit -qm init --allow-empty && bash "$R" goal "g" >/dev/null 2>&1 )
o="$(cd "$wb" && bash "$H" 2>/dev/null)"
case "$o" in *"5. **Drive lanes.**"*) pass;; *) fail "with a board the hook output carries the loop";; esac
n="$(printf '%s' "$o" | wc -c | tr -d ' ')"
if command -v jq >/dev/null 2>&1; then
  n="$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext' | wc -c | tr -d ' ')"
  assert_eq "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.hookEventName')" "SessionStart" "hook output is the SessionStart shape"
fi
[ "$n" -le 10000 ] && pass || fail "hook context is $n characters; over 10,000 the harness replaces it with a file pointer"
grep -q 're-invoke the orchestrate skill' "$SD/runtime/hooks/on-compaction.sh" && fail "the reground hook still asks for a reload" || pass

# 6) rules: prints a reference by bare name, refuses a path.
bash "$R" rules status-page-rules | grep -q 'Progress page' && pass || fail "ledger.sh rules prints a reference"
bash "$R" rules ../SKILL >/dev/null 2>&1; assert_eq "$?" 2 "ledger.sh rules refuses a path"
bash "$R" rules nope >/dev/null 2>&1; assert_eq "$?" 2 "ledger.sh rules fails on an unknown name"
