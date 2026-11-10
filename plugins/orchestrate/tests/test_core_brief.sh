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
[ "$w" -le 15000 ] && pass || fail "SKILL.md is $w characters; a compaction re-attaches only its first 5,000 tokens"

# 2) Content: no frontmatter, the whole loop, the journal rule, the helper-on-PATH line,
#    and the absolute path the references are read from.
case "$core" in "---"*) fail "core carries frontmatter";; *) pass;; esac
for m in '1. **Reground.**' '2. **Intake and goal.**' '3. **Clarify' '4. **Right-size.**' '5. **Drive lanes.**' '6. **Verify**' '7. **Land**' '8. **Feedback.**' \
         'Never end a turn with a dispatch' 'Journal only canonical events' 'fresh `dispatch_id`' 'T2: the full chain' 'orchestrate:complete' 'open a pull request' 'implementer once' 'prod-ack:<target>' 'One dispatch at a time on a shared' 'halts only its own' 'are on your PATH' 'again after a compaction' "$SD/references/"; do
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
grep -qF '!`"${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh" brief`' "$I" && pass || fail "init.md injects the brief (core plus every-run references)"
grep -qF 'allowed-tools: Bash("${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh" brief)' "$I" && pass || fail "init.md pre-approves the injected command"
assert_eq "$(awk 'f==2{print} /^---[[:space:]]*$/{f++}' "$I" | grep -c 'ledger.sh" brief')" 1 "the injection survives the installers' frontmatter split (no --- rule in the body)"
br="$(bash "$SK/bin/ledger.sh" brief)"; assert_eq "$?" 0 "the bin shim the command calls prints the brief"
for m in '5. **Drive lanes.**' '# Right-sizing and context economy' '# Dispatching' '# Routing and quarantine' '| **T0** |' 'DECISION_FORK:' '# Review rounds' '# Shared targets and production changes' '# Worktrees and landing'; do
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
[ "$n" -le 10000 ] && pass || fail "raw hook output is $n characters (JSON escaping included); the cap is 10,000"
if command -v jq >/dev/null 2>&1; then
  n="$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext' | wc -c | tr -d ' ')"
  assert_eq "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.hookEventName')" "SessionStart" "hook output is the SessionStart shape"
fi
[ "$n" -le 10000 ] && pass || fail "hook context is $n characters; over 10,000 the harness replaces it with a file pointer"
grep -q 're-invoke the orchestrate skill' "$SD/runtime/hooks/on-compaction.sh" && fail "the reground hook still asks for a reload" || pass

# 6) rules: prints a reference by bare name, refuses a path.
bash "$R" rules status-page-rules | grep -q 'Progress page' && pass || fail "ledger.sh rules prints a reference"
bash "$R" rules ../SKILL >/dev/null 2>&1; assert_eq "$?" 2 "ledger.sh rules refuses a path"

# 7) Injected text can never abort the command: a plugin root with a space in it works,
#    and a broken install prints one line and exits 0 (a failed injection would abort the
#    whole command before the model saw anything).
sp="$(mktemp -d)/my plugins/orchestrate"; mkdir -p "$sp"; cp -RL "$SK/bin" "$SK/skills" "$sp/" 2>/dev/null
o="$(CLAUDE_PLUGIN_ROOT="$sp" bash -c "$(grep -o '"${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh" brief' "$I" | head -1)")"; assert_eq "$?" 0 "the injected command line runs from a plugin root with a space in it"
case "$o" in *"5. **Drive lanes.**"*) pass;; *) fail "and prints the brief from there";; esac
o="$(CLAUDE_PLUGIN_ROOT="$sp" bash -c "$(grep -o '"${CLAUDE_PLUGIN_ROOT}/bin/ledger.sh" rules status-page-rules' "$SK/commands/status.md" | head -1)")"; assert_eq "$?" 0 "the status command's injected line runs from a spaced path too"
mv "$sp/skills/orchestrate/SKILL.md" "$sp/skills/orchestrate/SKILL.md.gone"
o="$(bash "$sp/bin/ledger.sh" brief)"; assert_eq "$?" 0 "a missing core does not fail the injected command"
case "$o" in *"could not be printed"*"Load the orchestrate skill"*) pass;; *) fail "it says what to do instead ($o)";; esac
bash "$sp/bin/ledger.sh" core >/dev/null 2>&1; assert_eq "$?" 2 "core itself still fails loudly (the hook then prints nothing)"
o="$(bash "$R" rules no-such-reference)"; assert_eq "$?" 0 "a missing reference does not fail an injected rules line"
bash "$R" rules -x >/dev/null 2>&1; assert_eq "$?" 2 "a leading dash is misuse"
printf 'no frontmatter here\n' > "$sp/skills/orchestrate/SKILL.md"
bash "$sp/bin/ledger.sh" core >/dev/null 2>&1; assert_eq "$?" 2 "a SKILL.md with no frontmatter prints no half-core"

# 8) Each command's pre-approval is exactly the command it injects, and the injection is
#    its own line (the allowed-tools line alone must not satisfy these).
for f in "$SK/commands/init.md" "$SK/commands/status.md"; do
  inj="$(grep -E '^!`.*`$' "$f" | sed 's/^!`//; s/`$//')"
  alw="$(sed -n 's/^allowed-tools: Bash(\(.*\))$/\1/p' "$f")"
  [ -n "$inj" ] && pass || fail "$(basename "$f") has an injection line"
  assert_eq "$alw" "$inj" "$(basename "$f") pre-approves exactly what it injects"
done

# 9) The re-attach only fires where a run was driven: an empty board, or one holding only
#    another session's refused command, prints nothing; and the text says who it is for.
eb="$(mktemp_repo)"; mkdir -p "$eb/.agents/runs/orchestrate"; : > "$eb/.agents/runs/orchestrate/board.jsonl"
assert_eq "$(cd "$eb" && bash "$H" 2>&1)" "" "empty board: the hook prints nothing"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"denied","hook":"floor","persona":"-","note":"x"}' > "$eb/.agents/runs/orchestrate/board.jsonl"
assert_eq "$(cd "$eb" && bash "$H" 2>&1)" "" "a board with only a refused command: the hook prints nothing"
case "$(cd "$wb" && bash "$H" 2>/dev/null)" in *"Any other session: ignore this"*) pass;; *) fail "the re-attach says who it is for";; esac

# 10) brief never fails on a missing reference (a failed injection aborts the start
#     command), and names the one it could not print.
mr="$(mktemp -d)"; cp -R "$SD" "$mr/orchestrate"
for gone in landing sizing; do
  rm -f "$mr/orchestrate/references/$gone.md"
  o="$(bash "$mr/orchestrate/runtime/ledger.sh" brief 2>/dev/null)"; assert_eq "$?" 0 "brief exits 0 with $gone.md missing"
  case "$o" in *"the reference $gone could not be printed"*) pass;; *) fail "brief names the missing reference $gone";; esac
done
rm -rf "$mr"
