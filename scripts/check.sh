#!/usr/bin/env bash
# Run what CI runs (.github/workflows/tests.yml calls this same script, one job
# per section, so there is one source of truth).
#
#   scripts/check.sh                  # every section
#   scripts/check.sh <section>...     # plugin-tests | validate-plugins |
#                                     # review-workflow-guards | library-wiring
#
# Locally, a missing tool (yq, rumdl, claude) is reported as SKIPPED: its section
# (or, for plugin-tests, the suite tests that need it) does not run, and a skip is
# not a pass, because CI will still run it. Under CI (CI=true) a missing tool is a
# failure. Exits nonzero if anything that ran failed.
#
# CI installs the LATEST @anthropic-ai/claude-code, unpinned. A validator failure
# that also reproduces on main is not "pre-existing" unless main's latest CI run is
# red on the same check (gh run list --branch main --workflow tests); otherwise it
# is CLI drift and it blocks the change.
set -uo pipefail
cd "$(dirname "$0")/.."
exec </dev/null   # hooks under test read stdin; never inherit git's (pre-push) stdin

failed=() skipped=()
in_ci() { [ "${CI:-}" = true ]; }
group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else echo "== $*"; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
have_yq4() { command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qE 'mikefarah|version v?4\.'; }

# need <section> <tool-label> <test-cmd...>: 0 if present; else skip (local) or fail (CI).
need() {
  local section="$1" tool="$2"; shift 2
  "$@" && return 0
  if in_ci; then echo "FAIL [$section]: $tool not installed"; failed+=("$section"); else
    echo "SKIP [$section]: $tool not installed; CI has it, so install it to check locally."
    skipped+=("$section ($tool missing)"); fi
  return 1
}

plugin_tests() {
  local found=0 t
  # Without these the suites still run but self-skip the tests that need them.
  need plugin-tests "yq v4 (mikefarah)" have_yq4
  need plugin-tests rumdl have rumdl
  for t in plugins/*/tests/run.sh; do
    [ -f "$t" ] || continue
    found=1
    group "$t"
    bash "$t" || failed+=("plugin-tests: $t")
    endgroup
  done
  if [ "$found" -eq 0 ]; then echo "no plugin suites found"; failed+=("plugin-tests: no suites"); fi
}

validate_plugins() {
  need validate-plugins "claude CLI" have claude || return 0
  echo "claude $(claude --version 2>/dev/null) (CI uses the latest release)"
  bash scripts/validate-plugins.sh || failed+=("validate-plugins")
}

review_workflow_guards() {
  local wf=.github/workflows/claude-code-review.yml perm cond
  need review-workflow-guards "yq v4 (mikefarah)" have_yq4 || return 0
  # A read-only token lets the review run to completion, hit dozens of silent
  # permission denials, then exit green having posted nothing. Assert the grant
  # statically so nobody pays to rediscover that.
  perm=$(yq '.jobs.claude-review.permissions.pull-requests' "$wf")
  if [ "$perm" != "write" ]; then
    echo "claude-review needs 'pull-requests: write' to post its review; found: $perm"
    failed+=("review-workflow-guards: pull-requests write")
  else echo "claude-review has pull-requests: write."; fi
  cond=$(yq '.jobs.claude-review.if' "$wf")
  case "$cond" in
    *"head.repo.full_name == github.repository"*) echo "claude-review is gated to same-repo PRs." ;;
    *) echo "claude-review must be gated to same-repo PRs; found if: $cond"
       failed+=("review-workflow-guards: same-repo gate") ;;
  esac
}

library_wiring() {
  local broken filelinks
  # Symlinks resolve (library-view wiring, ADR-0036).
  broken=$(find plugins -type l ! -exec test -e {} \; -print)
  if [ -n "$broken" ]; then
    echo "Dangling symlinks (skills ship as empty components):"; echo "$broken"
    failed+=("library-wiring: dangling symlinks")
  else echo "All plugin symlinks resolve."; fi
  # No file symlinks: discovery skips them (ADR-0036). `-exec test -f` is the
  # portable spelling of GNU `-xtype f` (BSD find has no -xtype).
  filelinks=$(find plugins -type l -exec test -f {} \; -print)
  if [ -n "$filelinks" ]; then
    echo "Symlinked files are invisible to component discovery; symlink directories instead:"
    echo "$filelinks"
    failed+=("library-wiring: file symlinks")
  else echo "No file symlinks."; fi
}

sections=("$@")
[ ${#sections[@]} -gt 0 ] || sections=(plugin-tests validate-plugins review-workflow-guards library-wiring)
for s in "${sections[@]}"; do
  case "$s" in
    plugin-tests) plugin_tests ;;
    validate-plugins) validate_plugins ;;
    review-workflow-guards) review_workflow_guards ;;
    library-wiring) library_wiring ;;
    *) echo "unknown section: $s"; exit 2 ;;
  esac
done

echo
for s in ${skipped[@]+"${skipped[@]}"}; do echo "SKIPPED: $s"; done
if [ ${#failed[@]} -gt 0 ]; then
  for f in "${failed[@]}"; do echo "FAILED: $f"; done
  exit 1
fi
echo "check.sh: all run sections passed${skipped[0]+ (some skipped, see above)}."
