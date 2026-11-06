# Tier 2 — plugin-install smoke against the REAL `claude` CLI, at BOTH user scope and
# project (repo) scope. No API key needed: validate/marketplace/install/details make
# no model calls. Filesystem-isolated at the HOME+cwd level (not via CLAUDE_CONFIG_DIR
# / --scope-as-isolation): every `claude` runs with HOME and cwd pointed at throwaway
# dirs, so user-scope state (HOME/.claude) AND project-scope state (cwd/.claude) and
# the plugin cache all land in the sandbox — nothing touches the repo or real ~/.claude.
# Proves Claude Code ingests the packaged plugin and persists the enable at the right
# scope (the install gap the zero-dep suite can't reach).
if ! have_claude; then
  skip "tier2 plugin-install: claude CLI not on PATH"
else
  cc(){ ( cd "$work" && HOME="$h" claude "$@" ); }   # FS-isolated; uses current $h/$work

  # Isolation is asserted as "this test did not CHANGE real ~/.claude or the repo's
  # .claude" (before/after) — robust to whatever marketplaces already exist in the
  # ambient env, and the correct semantics since a sandboxed HOME structurally can't
  # leak. (An absolute "real config is empty" check would false-fail on pre-existing
  # user installs.)
  _iso(){ cat "$HOME/.claude/plugins/known_marketplaces.json" 2>/dev/null; echo "@@"; cat "$REPO_ROOT/.claude/settings.json" 2>/dev/null; }
  iso_before="$(_iso)"

  # --- Manifests validate (scope-independent) ---
  h="$(mk_home)"; work="$(mk_tmp)"
  cc plugin validate "$PLUGIN_DIR" >/dev/null 2>&1 && pass || fail "plugin.json validates (claude plugin validate)"
  cc plugin validate "$REPO_ROOT"  >/dev/null 2>&1 && pass || fail "marketplace.json validates (claude plugin validate)"

  # --- Install at BOTH user and project (repo) scope, each in its own sandbox ---
  for scope in user project; do
    h="$(mk_home)"; work="$(mk_tmp)"
    cc plugin marketplace add "$REPO_ROOT" >/dev/null 2>&1 && pass || fail "[$scope] marketplace add (local path)"
    cc plugin install orchestrate@ajilty --scope "$scope" >/dev/null 2>&1 && pass || fail "[$scope] plugin install --scope $scope"
    # list reports the expected scope
    if cc plugin list 2>/dev/null | grep -A4 'orchestrate@ajilty' | grep -qi "Scope: $scope"; then pass; else fail "[$scope] plugin list reports Scope: $scope"; fi
    # enable-state persists in the scope-appropriate settings file
    case "$scope" in
      user)    grep -qs 'orchestrate@ajilty' "$h/.claude/settings.json"  && pass || fail "[user] enable persisted to ~/.claude/settings.json";;
      project) grep -qs 'orchestrate@ajilty' "$work/.claude/settings.json" && pass || fail "[project] enable persisted to repo-local .claude/settings.json";;
    esac
    # inventory resolves at this scope
    case "$(cc plugin details orchestrate 2>/dev/null)" in *"Agents (5)"*) pass;; *) fail "[$scope] details reports 5 agents";; esac
  done

  # --- Component inventory detail (names + command + hooks), once ---
  h="$(mk_home)"; work="$(mk_tmp)"
  cc plugin marketplace add "$REPO_ROOT" >/dev/null 2>&1; cc plugin install orchestrate@ajilty >/dev/null 2>&1
  det="$(cc plugin details orchestrate 2>/dev/null)"
  for a in researcher planner implementer verifier actuator; do
    case "$det" in *"$a"*) pass;; *) fail "details lists agent: $a";; esac
  done
  case "$det" in *"init"*) pass;; *) fail "details lists the start command/skill (/orchestrate:init)";; esac
  case "$det" in *"Hooks (2)"*) pass;; *) fail "details reports 2 registered hook events (PreToolUse, SessionStart; ADR-0040)";; esac

  # --- Isolation self-check: the test did not mutate real ~/.claude or the repo .claude ---
  if [ "$(_iso)" = "$iso_before" ]; then pass; else fail "test mutated real ~/.claude or repo .claude (FS isolation leak)"; fi
fi
