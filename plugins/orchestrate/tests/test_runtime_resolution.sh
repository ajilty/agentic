#!/usr/bin/env bash
# test_runtime_resolution.sh — the bin/ shims expose the runtime helpers on PATH so the
# LLM-facing bare `ledger.sh` / `adr.sh` (SKILL.md, personas) resolve in
# every execution context, where ${CLAUDE_PLUGIN_ROOT} is not injected (ADR-0018).
BIN="$HERE/../bin"

# 1) each helper has a committed, executable shim.
for n in ledger adr; do
  assert_file "$BIN/$n.sh"
  [ -x "$BIN/$n.sh" ] && pass || fail "bin/$n.sh is executable"
done

# 2) bare name resolves to the bin shim when bin/ is on PATH, from an unrelated cwd.
got="$(cd /tmp && PATH="$BIN:$PATH" command -v adr.sh)"
case "$got" in */bin/adr.sh) pass;; *) fail "adr.sh resolves to the bin shim on PATH (got '$got')";; esac

# 3) the shim execs the REAL runtime helper (its usage banner proves we reached runtime/adr.sh).
out="$(cd /tmp && PATH="$BIN:$PATH" adr.sh 2>&1 | head -1)"
case "$out" in *'usage: adr.sh'*) pass;; *) fail "bin/adr.sh shim execs runtime adr.sh (got '$out')";; esac

# 4) the shim keeps the caller's cwd (the cd is in a subshell), so adr.sh reads docs/adr
#    relative to where it was invoked — not relative to the plugin.
d="$(mktemp_repo)"; ( cd "$d" && mkdir -p docs/adr && : > docs/adr/0003-x.md )
got2="$(cd "$d" && PATH="$BIN:$PATH" adr.sh next)"
assert_eq "$got2" "0004" "shim runs helper in caller cwd (docs/adr numbering)"
rm -rf "$d"
