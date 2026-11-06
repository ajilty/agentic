# Tier 3 (OpenCode install, static — no auth needed) — the compiled orchestrate.ts
# must actually PARSE under OpenCode's TS-stripping runtime, wire shell.env and
# session.compacted only, and land every generated
# surface (agents/, commands/, plugins/, skill) exactly where a live `opencode`
# reads from. Guards on have_opencode (not have_opencode_auth) — this probe needs
# the CLI's bundled `node`/parsing behavior but no live model call, matching the
# work item's "static, no auth needed" framing; still self-skips per the
# acceptance oracle's "PATH stripped of opencode -> SKIP, not FAIL" contract.
if ! have_opencode; then
  skip "opencode install: opencode CLI not on PATH"
else
  oc="$(mk_opencode_home)"
  opencode_install "$oc"
  cfg="$oc/.config/opencode"
  plug="$cfg/plugins/orchestrate.ts"

  if [ ! -f "$plug" ]; then
    fail "opencode install: no orchestrate.ts emitted at $plug"
  else
    pass
    # Syntax validity: OpenCode's bundled node must be able to strip+parse this
    # TS file. `node --check` alone chokes on TS syntax (types, `as`, etc.), so
    # prefer --experimental-strip-types when the host node supports it; fall back
    # to a plain syntax skip (not a fail) rather than asserting on an unsupported
    # host node.
    if command -v node >/dev/null 2>&1; then
      # (import, not --check: newer node's --check does not strip types; the module only declares an export)
      if node --experimental-strip-types --no-warnings -e 'import(process.argv[1])' "$plug" >/tmp/oc_install_check.$$ 2>&1; then
        pass   # orchestrate.ts parses under strip-types
      else
        if grep -qi "unknown or unexpected option" /tmp/oc_install_check.$$ 2>/dev/null; then
          skip "opencode install: host node lacks --experimental-strip-types — cannot syntax-check TS directly"
        else
          fail "opencode install: orchestrate.ts failed to parse: $(head -3 /tmp/oc_install_check.$$)"
        fi
      fi
      rm -f /tmp/oc_install_check.$$
    else
      skip "opencode install: no node on PATH to syntax-check the emitted TS"
    fi

    # 0.9.0: the plugin has no tool.execute.before floor (ADR-0040).
    ! grep -q 'tool.execute.before' "$plug" && pass || fail "opencode install: plugin still wires tool.execute.before"
    grep -q 'hooks/on-compaction.sh' "$plug" && pass || fail "opencode install: plugin does not run on-compaction.sh"

    # Documented hooks only (ADR-0034 resolution 2026-07-21): shell.env +
    # session.compacted wired, and NO subagent.start (not a documented event —
    # writer write-ahead is in-loop). test_opencode_compaction_event.sh remains
    # the live arbiter of whether session.compacted actually fires.
    if grep -q '"shell.env"' "$plug" && grep -q '"session.compacted"' "$plug" && ! grep -q '"subagent.start"' "$plug"; then
      pass   # documented hook set exactly (compaction firing bounded live by test_opencode_compaction_event.sh)
    else
      fail "opencode install: expected shell.env + session.compacted and NO subagent.start — installer output changed shape"
    fi
  fi

  # File placement: agents/ (5 personas), commands/ (3), skill dir (SKILL.md +
  # runtime/ + references/) exactly where a live opencode with this HOME/XDG set
  # would read them from (same vars oc_run uses — no separate path arithmetic).
  n_agents="$(find "$cfg/agents" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "${n_agents:-0}" 5 "opencode install: 5 persona agent files"
  n_cmds="$(find "$cfg/commands" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "${n_cmds:-0}" 3 "opencode install: 3 command files"
  [ -f "$oc/.agents/skills/orchestrate/SKILL.md" ] && pass || fail "opencode install: skill did not land at HOME/.agents/skills/orchestrate/SKILL.md"
  [ -x "$oc/.agents/skills/orchestrate/runtime/hooks/on-compaction.sh" ] && pass || fail "opencode install: on-compaction.sh not installed executable in the skill's runtime"
  cd /
fi
