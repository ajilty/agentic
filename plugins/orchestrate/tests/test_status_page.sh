# Progress-page mode (0.9.5): the status command can keep an operator-facing
# page beside its inline report. Deterministic checks only: the template carries
# every required section, a fill from the sample board produced every section
# with board-derived content, and the command/SKILL prose carries the rules the
# router must follow (offer once per goal, journal on the goal anchor, refresh
# on the liveness tick, corrections as entries).
SK="$HERE/.."
TPL="$SK/skills/orchestrate/references/status-page.html"
SAMPLE="$HERE/fixtures/status-page/status.html"
BOARD="$HERE/fixtures/status-page/board.jsonl"
CMD="$SK/commands/status.md"
SKILL="$SK/skills/orchestrate/SKILL.md"

# 1) The nine sections, template and sample both. Markers are the render ids /
#    fixed headings the page contract names (brief sections 1-9).
for f in "$TPL" "$SAMPLE"; do
  for m in 'id="eyebrow"' 'id="headline"' 'id="sublead"' 'Changed since last update' \
           'id="legend"' 'id="rows"' 'My read, not a commitment' \
           'Calls that are yours' 'Earlier updates' 'How to read this page'; do
    grep -qF "$m" "$f" && pass || fail "$(basename "$f") carries section marker: $m"
  done
done

# 2) The sample is a fill of the TEMPLATE from the SAMPLE BOARD, not a fork:
#    outside the DATA block the two files must be identical (the skeleton and
#    render never change on a refresh), and board facts must surface on the page.
awk 'f{print} /RENDER/{f=1}' "$TPL" > "${TMPDIR:-/tmp}/tpl.render.$$"
awk 'f{print} /RENDER/{f=1}' "$SAMPLE" > "${TMPDIR:-/tmp}/sample.render.$$"
diff -q "${TMPDIR:-/tmp}/tpl.render.$$" "${TMPDIR:-/tmp}/sample.render.$$" >/dev/null && pass || fail "sample render script identical to template (refresh edits DATA only)"
rm -f "${TMPDIR:-/tmp}/tpl.render.$$" "${TMPDIR:-/tmp}/sample.render.$$"
grep -q '"fork_id":"prod-ack:prod-env"' "$BOARD" && grep -qi 'production apply' "$SAMPLE" && pass || fail "the board's pending prod-ack surfaces on the sample page"
grep -q '"verdict":"REJECTED"' "$BOARD" && grep -qi 'bounced once' "$SAMPLE" && pass || fail "the board's reject round is told in outcome terms on the sample page"
grep -q '(corrected)' "$SAMPLE" && pass || fail "sample changelog shows a correction as its own entry"
grep -q 'fork_id":"status-page"' "$BOARD" && pass || fail "sample board journals the page acceptance on the goal anchor"

# 3) No raw internals leak onto the page: ticket ids, persona names, dispatch ids.
for leak in 'guard-branch' 'runner-trust' 'implementer' 'verifier' 'dispatch_id' 'd03'; do
  grep -qF "$leak" "$SAMPLE" && fail "sample page leaks internal identifier: $leak" || pass
done

# 4) The command carries the operating rules the router follows.
for m in 'inline stays the default' 'exactly once per goal' 'fork_id":"status-page' \
         'timezone' 'hourly' '(corrected)' 'liveness re-entry tick' \
         'merge into it'; do
  grep -qiF "$m" "$CMD" && pass || fail "status.md carries progress-page rule: $m"
done

# 5) The liveness tick knows about the page, and reground re-arms the schedule.
grep -q 'status-page' "$SKILL" && pass || fail "SKILL step 5 ties the page refresh to the re-entry tick"
if grep -qi 're-arm' "$CMD" || grep -qi 're-arms' "$SKILL"; then pass; else fail "reground re-arms the refresh schedule"; fi
