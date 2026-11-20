#!/usr/bin/env bash
# Litmus without a model: the judge's arithmetic, and the engine and the
# comparison command end to end against a stand-in for the claude CLI
# (tests/fake_claude.py). No model call, no network, no spend.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# A skip is said out loud and passes locally; in CI it fails, because there the suite must run.
skip(){ echo "(skip litmus tests: $1)"; [ "${CI:-}" != true ] || { echo "litmus: CI must run these tests" >&2; exit 1; }; exit 0; }
command -v python3 >/dev/null 2>&1 || skip "no python3"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || skip "python3 older than 3.11"
[ -d /var/tmp ] && [ -w /var/tmp ] || skip "/var/tmp is not writable"
# The engine refuses to run where an instruction file above the run folder would load too. On a machine
# with one above /var/tmp the tests cannot run as written; say so instead of failing them all.
why="$(python3 -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import engine
engine.MANAGED = ()
try: engine.check_run_root("/var/tmp/litmus-test-probe/runs")
except engine.EngineError as e: print(e)' "$HERE")"
[ -z "$why" ] || skip "$why"
exec python3 "$HERE/tests/test_litmus.py" "$@"
