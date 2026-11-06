# Tier 3 (Codex clarify-gate precondition, deterministic) — the O6 front-door clarify-gate
# selects a clarification mechanism by FIRST-PRESENT down grill-with-docs -> grill-me ->
# brainstorming -> inline (SKILL.md loop step 3). On a stock Codex install only `find-skills` ships in
# ~/.codex/skills; grill-me / brainstorming are NOT present. Per ADR-0015 the gate must
# therefore fall through to `inline` (a non-interactive session's clarification is still a
# clarification). This asserts the PRECONDITION that makes that fall-through faithful: the
# sandbox CODEX_HOME skills dir genuinely lacks grill-me AND brainstorming. If a future
# install seeds them, this fixture flags that the gate would no longer fall to inline.
if ! have_codex; then
  skip "codex clarify-gate: codex CLI not on PATH"
else
  ch="$(mk_codex_home)"
  codex_install "$ch"
  # Inspect the sandbox skills dir (never the real ~/.codex). A clean throwaway CODEX_HOME
  # has no homegrown clarification skills cloned in — only auth + the generated install.
  skills_dir="$ch/skills"
  has(){ [ -e "$skills_dir/$1" ] || [ -e "$skills_dir/$1.md" ] || [ -d "$skills_dir/$1" ]; }
  if has grill-me || has brainstorming; then
    fail "codex clarify-gate: sandbox CODEX_HOME unexpectedly has grill-me/brainstorming — gate would NOT fall to inline"
  else
    pass   # precondition holds: no grill-me/brainstorming -> clarify-gate correctly falls to `inline` (ADR-0015)
  fi
  cd /
fi
