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

# 6) Freshness (0.9.6): the page carries a machine timestamp and a cadence, and
#    draws its own out-of-date banner from them; the template and the sample both.
for f in "$TPL" "$SAMPLE"; do
  grep -q 'updated_at: "' "$f" && grep -q 'cadence_minutes: ' "$f" && pass || fail "$(basename "$f") carries updated_at + cadence_minutes"
  grep -q 'id="stale"' "$f" && grep -q '2 \* cad' "$f" && grep -q 'setInterval(staleCheck' "$f" && pass || fail "$(basename "$f") draws the out-of-date banner at twice the cadence and re-checks"
done
grep -q 'updated_at: "20[0-9-]*T[0-9:]*Z"' "$SAMPLE" && pass || fail "sample fills updated_at in UTC (date -u +%FT%TZ)"
if command -v node >/dev/null 2>&1; then
  # Behaviour, not just markup: run the banner logic against a fake DOM.
  js="$(awk '/const staleCheck/,/^staleCheck\(\);/' "$TPL" | sed 's/^staleCheck(); setInterval(staleCheck, 60000);$//')"
  for case_ in "0:hidden" "130:shown" "bad:shown"; do
    age="${case_%%:*}" want="${case_#*:}"
    out="$(node -e "
      const el={hidden:true,textContent:''}; const \$=()=>el;
      const DATA={cadence_minutes:60, updated_at: '$age'==='bad' ? 'FILL' : new Date(Date.now()-$([ "$age" = bad ] && echo 0 || echo "$age")*60000).toISOString()};
      $js
      staleCheck(); console.log(el.hidden?'hidden':'shown');")"
    [ "$out" = "$want" ] && pass || fail "banner $want at age $age min (got $out)"
  done
fi

# 7) The journal helper reminds the router to refresh on lane changes, only while
#    the current goal's page is accepted, and never for the page's own rows.
R="$SK/skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; ( cd "$d"
  bash "$R" goal "g1" >/dev/null 2>&1
  w="$(bash "$R" append '{"ticket":"T1","event":"dispatched","persona":"verifier","dispatch_id":"d1"}' 2>&1)"
  [ -z "$w" ] && pass || fail "no page reminder before a page is accepted ($w)"
  w="$(bash "$R" decision T1 status-page "" "accepted: https://example.invalid tz=ET cadence=hourly" 2>&1)"
  [ -z "$w" ] && pass || fail "the page's own acceptance row does not nudge ($w)"
  w="$(bash "$R" append '{"ticket":"T1","event":"returned","dispatch_id":"d1"}' 2>&1)"
  case "$w" in *"progress page is on"*) pass;; *) fail "lane change nudges once the page is accepted ($w)";; esac
  w="$(bash "$R" done T1 2>&1)"
  case "$w" in *"progress page is on"*) pass;; *) fail "done nudges once the page is accepted ($w)";; esac
  w="$(bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}' 2>&1)"
  [ -z "$w" ] && pass || fail "intake is not a lane state change ($w)"
  bash "$R" goal "g2" >/dev/null 2>&1
  w="$(bash "$R" append '{"ticket":"T2","event":"dispatched","persona":"planner","dispatch_id":"d2"}' 2>&1)"
  [ -z "$w" ] && pass || fail "a new goal starts with the page off ($w)"
)

# 8) Prose budgets: the template and sample pass; an overgrown page fails and names fields.
bash "$R" page-check "$TPL" >/dev/null && pass || fail "template passes page-check"
bash "$R" page-check "$SAMPLE" >/dev/null && pass || fail "sample passes page-check"
big="${TMPDIR:-/tmp}/bigpage.$$"
cat > "$big" <<'PAGE'
const DATA = {
  headline: "Midway, not done. Monday's maintenance window is finished and CI is live; the rest of the rework is running without you, target Wed Nov 18.",
  sublead: "Just landed: one. Running now: two. Then three. Credential rotation runs last by your call, with dev previews and key escrow behind it and more words here.",
  changed: ["a", "b", "c", "d", "e", "f"],
  needs: ["Nothing blocking. Your end batch, a few minutes each, whenever convenient: (1) restore test from its own pre-rebuild backup and fresh-install dev (recommended). (2) Accept the registry pull-token residual. At the very end: mint new credentials in each vendor site."],
};
PAGE
out="$(bash "$R" page-check "$big")" && fail "overgrown page fails page-check" || pass
for m in 'headline: ' 'headline: 2 sentences' 'sublead: 4 sentences' 'changed: 6 bullets' 'needs item 1: '; do
  case "$out" in *"$m"*) pass;; *) fail "page-check reports: $m";; esac
done

# Review-found parser edges: history t is measured (not its "at" stamp); a multi-line
# array closed on its last item's line ends there; every string on a line counts;
# abbreviations are not sentence ends; an unparseable page fails closed.
cat > "$big" <<'PAGE'
const DATA = {
  headline: "Done e.g. the guard is live at 11 a.m. ET today.",
  changed: [
    "a", "b",
    "c"],
  tiles: [
    {v: "1", l: "x"},
    {v: "2", l: "y"},
    {v: "3", l: "z"}
  ],
  history: [
    {at: "Nov 8", t: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix"}
  ]
};
PAGE
out="$(bash "$R" page-check "$big")"; rc=$?
assert_eq "$rc" 1 "page-check fails on the over-budget history entry only"
case "$out" in *"made/history entry: 26 words"*) pass;; *) fail "history t is measured, not its at stamp ($out)";; esac
case "$out" in *"bullets"*) fail "array closed on its last line does not swallow tiles ($out)";; *) pass;; esac
case "$out" in *"headline"*) fail "abbreviations are not sentence ends ($out)";; *) pass;; esac
printf 'const DATA = {\n  changed: [\n    "a", "b", "c",\n    "d", "e", "f"\n  ],\n  headline: "ok."\n};\n' > "$big"
out="$(bash "$R" page-check "$big")"
case "$out" in *"changed: 6 bullets"*) pass;; *) fail "every string on a line counts toward bullets ($out)";; esac
printf '<html>no data here</html>\n' > "$big"
bash "$R" page-check "$big" >/dev/null 2>&1; assert_eq "$?" 2 "page-check fails closed on a page it cannot parse"
printf 'const DATA = {\n    headline: "Indented four spaces, one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen."\n};\n' > "$big"
out="$(bash "$R" page-check "$big")"
case "$out" in *"headline: "*words*) pass;; *) fail "re-indented DATA is still checked ($out)";; esac
rm -f "$big"

# 9) The command carries the rewrite-not-extend rule, the banner fields, and the migration note.
for m in 'Rewrite, never extend' 'page-check' 'updated_at' 'cadence_minutes' 'never end a turn that journaled a lane' 'created before 0.9.6'; do
  grep -qF "$m" "$CMD" && pass || fail "status.md carries: $m"
done
