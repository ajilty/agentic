SK="$HERE/.."   # plugins/orchestrate
have_yq4 || { echo "(skip test_install: $YQ4_SKIP)"; return 0 2>/dev/null || true; }
d="$(mktemp_repo)"; cd "$d"
# codex: emits ALL five personas, honors --dir (no AGENTS.orchestrate.md anywhere — the
# brain is now a NATIVE skill under .agents/skills, ADR-0034), ships runtime inside it
o="${TMPDIR:-/tmp}/p4cx.$$"; rm -rf "$o"; bash "$SK/scripts/install-codex.sh" --scope project --dir "$o" >/dev/null 2>&1
SKD="$o/.agents/skills/orchestrate"
for p in researcher planner implementer verifier actuator; do assert_file "$o/agents/$p.toml"; done
assert_no_file "AGENTS.orchestrate.md"
assert_no_file "$o/AGENTS.orchestrate.md"
assert_file "$SKD/SKILL.md"
grep -q '^name: orchestrate' "$SKD/SKILL.md" && pass || fail "codex skill keeps the frontmatter name (skills standard)"
grep -q 'Codex dispatch addendum' "$SKD/SKILL.md" && pass || fail "codex skill carries the dispatch addendum (ADR-0034/0040)"
grep -qE 'dispatch-persona|worktree\.sh' "$SKD/SKILL.md" && fail "codex addendum mentions a deleted script" || pass
grep -q "export PATH=\"$SKD/runtime" "$SKD/SKILL.md" && pass || fail "addendum embeds the absolute runtime PATH line (ADR-0018)"
assert_file "$SKD/references/resume.md"
test -x "$SKD/runtime/ledger.sh" && pass || fail "codex ships ledger.sh executable inside the skill"
# capability -> sandbox_mode mapping: any write- or run-capable persona = workspace-write.
# Under the disk-first read lane (ADR-0014) the researcher writes its own findings, so it
# is workspace-write at the OS layer and confined to findings/_quarantine by the
# write-scope hook (two layers, same posture as the planner). actuator (run) = workspace-write.
grep -q 'sandbox_mode = "workspace-write"' "$o/agents/researcher.toml" && pass || fail "codex researcher sandbox_mode=workspace-write (results-only, hook-scoped)"
grep -q 'sandbox_mode = "workspace-write"' "$o/agents/actuator.toml" && pass || fail "codex actuator sandbox_mode=workspace-write"
# 0.9.0: codex gets agents and the skill only (no hooks.json, config.toml, trust seeding, second runtime copy)
assert_no_file "$o/hooks.json"
assert_no_file "$o/config.toml"
[ ! -d "$o/orchestrate-runtime" ] && pass || fail "codex no longer ships a second runtime copy at CODEX_HOME"
rm -rf "$o"
# opencode: five personas in agents/ (plural, docs-current), native skill, plugin,
# command parity — and no AGENTS.orchestrate.md
o="${TMPDIR:-/tmp}/p4oc.$$"; rm -rf "$o"; bash "$SK/scripts/install-opencode.sh" --scope project --dir "$o" >/dev/null 2>&1
SKD="$o/.agents/skills/orchestrate"
for p in researcher planner implementer verifier actuator; do assert_file "$o/agents/$p.md"; done
assert_no_file "AGENTS.orchestrate.md"
assert_no_file "$o/AGENTS.orchestrate.md"
assert_file "$SKD/SKILL.md"
grep -q 'OpenCode dispatch addendum' "$SKD/SKILL.md" && pass || fail "opencode skill carries its dispatch addendum (ADR-0034)"
test -x "$SKD/runtime/ledger.sh" && pass || fail "opencode ships ledger.sh executable inside the skill"
assert_file "$o/plugins/orchestrate.ts"
grep -q 'session.compacted' "$o/plugins/orchestrate.ts" && pass || fail "opencode plugin wires the documented session.compacted event"
# 0.9.0: the plugin keeps exactly PATH injection and compaction recovery
grep -q 'shell.env' "$o/plugins/orchestrate.ts" && pass || fail "opencode plugin injects PATH via shell.env"
grep -q 'hooks/on-compaction.sh' "$o/plugins/orchestrate.ts" && pass || fail "opencode plugin runs on-compaction.sh"
! grep -q 'tool.execute.before' "$o/plugins/orchestrate.ts" && pass || fail "opencode plugin has no tool.execute.before floor"
grep -q "$SKD/runtime" "$o/plugins/orchestrate.ts" && pass || fail "opencode plugin points at the skill's runtime (single copy)"
for c in init status feedback; do assert_file "$o/commands/orchestrate-$c.md"; done
grep -q -- '--models=' "$o/commands/orchestrate-init.md" && fail "opencode init command still carries the dropped --models flag (ADR-0040)" || pass
# command descriptions are parsed from the commands/*.md source frontmatter, never restated
for c in init status feedback; do
  want="$(yq --front-matter=extract '.description' "$SK/commands/$c.md")"
  got="$(yq --front-matter=extract '.description' "$o/commands/orchestrate-$c.md")"
  assert_eq "$got" "$want" "opencode $c command description matches source frontmatter"
done
# tier -> model emission (D1: Anthropic ladder default, env-overridable)
grep -q '^model: ' "$o/agents/planner.md" && pass || fail "opencode planner carries tier model"
grep -q '^model: anthropic/' "$o/agents/researcher.md" && pass || fail "opencode researcher model defaults to the Anthropic ladder"
# permission: layer emitted alongside deprecated tools: (read-only persona denies edit+bash)
grep -A3 '^permission:' "$o/agents/planner.md" | grep -q 'bash: deny' && pass || fail "opencode planner permission denies bash"
grep -A3 '^permission:' "$o/agents/implementer.md" | grep -q 'bash: allow' && pass || fail "opencode implementer permission allows bash"
rm -rf "$o"
cd /; rm -rf "$d"
