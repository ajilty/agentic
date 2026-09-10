#!/usr/bin/env bash
# Zero-dependency assertion helpers for guards hook tests.
set -uo pipefail
PASS=0; FAIL=0; SKIP=0
pass(){ PASS=$((PASS+1)); }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
skip(){ SKIP=$((SKIP+1)); printf 'SKIP: %s\n' "$1" >&2; }
assert_eq(){ [ "$1" = "$2" ] && pass || fail "${3:-} (got '$1' want '$2')"; }
assert_contains(){ case "$1" in *"$2"*) pass ;; *) fail "${3:-} (output lacks '$2')" ;; esac; }

# Hook payloads as Claude Code delivers them on stdin.
file_payload(){ jq -cn --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f}}'; }
bash_payload(){ jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# run_hook <script> <payload-json>: sets RC and ERR (stderr) for assertions.
run_hook(){ ERR=$(printf '%s' "$2" | bash "$1" 2>&1 >/dev/null); RC=$?; }

# Hermetic HOME/XDG so a developer's own rumdl config never leaks into a test.
TESTHOME="$(mktemp -d)"; export HOME="$TESTHOME" XDG_CONFIG_HOME="$TESTHOME/.config"
mktemp_repo(){ local d; d="$(mktemp -d)"; ( cd "$d" && git init -q ); printf '%s\n' "$d"; }
