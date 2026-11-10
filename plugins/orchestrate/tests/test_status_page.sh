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

# 3) No raw internals leak onto the page: ticket ids, persona names, dispatch ids. A
#    `ref` is the one place a ticket id belongs: it is never rendered (asserted below).
for leak in 'guard-branch' 'runner-trust' 'implementer' 'verifier' 'dispatch_id' 'd03'; do
  sed 's/, *ref: "[^"]*"//' "$SAMPLE" | grep -qF "$leak" && fail "sample page leaks internal identifier: $leak" || pass
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

# 10) Publish checks (0.9.6, ADR-0042). Field failure 2026-11-09/10: for about a day each
#     hourly refresh bumped the stamp and appended a history line; the rest of the page
#     stayed as written the night before. The stamp was fresh, the content stale.
NOW=2026-11-08T16:15:00Z
mkpage(){ # fresh repo holding the sample board + page; echoes the repo dir
  local d; d="$(mktemp_repo)"; cp "$BOARD" "$d/.agents/runs/orchestrate/board.jsonl"
  cp "$SAMPLE" "$d/.agents/runs/orchestrate/status.html"; printf '%s\n' "$d"; }
pc(){ ( cd "$1" && PAGE_CHECK_NOW="${2:-$NOW}" bash "$R" page-check --publish .agents/runs/orchestrate/status.html 2>/dev/null ); }
PG=.agents/runs/orchestrate/status.html; BD=.agents/runs/orchestrate/board.jsonl

d="$(mkpage)"; out="$(pc "$d")"; assert_eq "$?" 0 "the sample page agrees with the sample board and passes the publish check ($out)"

# 10a) THE REPRODUCTION. A quiet tick with nothing new: an unchanged page is fine. Then the
#      journal moves and the refresh touches only the stamp and the history: refused.
#      Rebuilding a field above the history clears it.
out="$(pc "$d")"; assert_eq "$?" 0 "quiet tick, nothing journaled since: an unchanged page still passes"
echo '{"ticket":"runner-trust","event":"verdict","verdict":"REJECTED","dispatch_id":"d09"}' >> "$d/$BD"
sed -i.bak -e 's/updated_at: "2026-11-08T16:10:00Z"/updated_at: "2026-11-08T17:10:00Z"/' \
  -e 's/updated: "Sun Nov 8, 11:10 am ET"/updated: "Sun Nov 8, 12:10 pm ET"/' \
  -e 's/^  history: \[/  history: [\'$'\n''    {at: "Nov 8, 12:10 pm", t: "Hourly refresh."},/' "$d/$PG"
out="$(pc "$d" 2026-11-08T17:12:00Z)"; assert_eq "$?" 1 "journal moved, only stamp + history touched: refused"
case "$out" in *"nothing on the page changed except the stamp and the history"*) pass;; *) fail "the stale-top refusal says what is wrong ($out)";; esac
sed -i.bak 's/headline: "Reviewed code is now/headline: "Runner change bounced; reviewed code is/' "$d/$PG"
out="$(pc "$d" 2026-11-08T17:12:00Z)"; assert_eq "$?" 0 "the same refresh with the top rebuilt passes ($out)"

# 10b) Finished work that still reads as upcoming, or as waiting on the operator.
d="$(mkpage)"; echo '{"ticket":"runner-trust","event":"done"}' >> "$d/$BD"
out="$(pc "$d")"; assert_eq "$?" 1 "a lane the board records done but the page shows running: refused"
case "$out" in *"Runner trust change in review"*"records runner-trust as done"*) pass;; *) fail "names the stale entry ($out)";; esac
d="$(mkpage)"; echo '{"ticket":"prod-apply","event":"decision","fork_id":"prod-ack:prod-env","note":"approved"}' >> "$d/$BD"
out="$(pc "$d")"; assert_eq "$?" 1 "an ask the operator already answered still listed: refused"
case "$out" in *"needs:"*"shows it answered"*) pass;; *) fail "names the satisfied ask ($out)";; esac

# 10c) Marked done or live without the evidence: no done row, no approved verdict.
d="$(mkpage)"; sed -i.bak 's/{state: "running", name: "Runner trust change in review"/{state: "done", name: "Runner trust change in review"/' "$d/$PG"
out="$(pc "$d")"; assert_eq "$?" 1 "an entry shown done with no done row or approved verdict: refused"
case "$out" in *"no done row or approved verdict for runner-trust"*) pass;; *) fail "names the unevidenced entry ($out)";; esac

# 10d) Finish dates that disagree (static: no board needed), and a top that names one
#      when the estimate card gives none (the live page said both "Nov 18" and "Re-estimating").
d="$(mkpage)"; sed -i.bak 's/{v: "1", l: "waiting on your go"}/{v: "Nov 12", l: "target to finish"}/' "$d/$PG"
out="$(bash "$R" page-check "$d/$PG")"; assert_eq "$?" 1 "a tile's finish date that differs from the estimate card: refused"
case "$out" in *"tiles: names Nov 12"*"estimate card says Nov 9"*) pass;; *) fail "names both dates ($out)";; esac
sed -i.bak 's/complete: "Complete Mon Nov 9, midday"/complete: "Re-estimating"/' "$d/$PG"
out="$(bash "$R" page-check "$d/$PG")"
case "$out" in *"estimate card gives no date"*) pass;; *) fail "a finish date with no estimate date is refused ($out)";; esac
d="$(mkpage)"; sed -i.bak 's/One open assumption about the runner image is listed where it belongs\./Backups lock from Nov 11./' "$d/$PG"
out="$(bash "$R" page-check "$d/$PG")"; assert_eq "$?" 0 "a milestone date that is not a finish claim is left alone ($out)"

# 10e) The stamp is the publish time: not stale, not in the future, and a real UTC stamp.
d="$(mkpage)"
out="$(pc "$d" 2026-11-08T18:00:00Z)"; assert_eq "$?" 1 "a stamp older than ten minutes at publish: refused"
out="$(pc "$d" 2026-11-08T16:00:00Z)"; assert_eq "$?" 1 "a stamp in the future: refused"
sed -i.bak 's/updated_at: "2026-11-08T16:10:00Z"/updated_at: "2026-11-08T11:10:00-05:00"/' "$d/$PG"
out="$(pc "$d")"; assert_eq "$?" 1 "a hand-written offset stamp: refused"

# 10f) Entries the check cannot tie to the journal: a missing ref is refused on needs,
#      pending and window; none: is allowed; an unknown ticket or fork is refused.
d="$(mkpage)"; sed -i.bak 's/, ref: "runner-trust"},$/},/' "$d/$PG"
out="$(pc "$d")"; assert_eq "$?" 1 "a window entry with no ref: refused"
d="$(mkpage)"; sed -i.bak 's/reviewer resolves it or bounces it.", ref: "runner-trust"/reviewer resolves it or bounces it.", ref: "none:external review"/' "$d/$PG"
out="$(pc "$d")"; assert_eq "$?" 0 "a none: ref is allowed ($out)"
d="$(mkpage)"; sed -i.bak 's/ref: "guard-branch"/ref: "no-such-ticket"/' "$d/$PG"
out="$(pc "$d")"; assert_eq "$?" 1 "a ref naming a ticket the board lacks: refused"

# 10g) Page code that does not parse (node present), and an old-style string ask.
if command -v node >/dev/null 2>&1; then
  d="$(mkpage)"; printf 'const broken = {;\n' >> "$d/extra.js"
  sed -i.bak 's#^const rows = #const broken = {;\nconst rows = #' "$d/$PG"
  out="$(bash "$R" page-check "$d/$PG")"; assert_eq "$?" 1 "page code that does not parse: refused"
  case "$out" in *"does not parse"*) pass;; *) fail "says the code does not parse ($out)";; esac
fi
d="$(mkpage)"; sed -i.bak 's/^    {t: "Your go on the production apply: \(.*\)", ref: "fork:prod-apply\/prod-ack:prod-env"}$/    "Your go on the production apply."/' "$d/$PG"
out="$(pc "$d")"; assert_eq "$?" 1 "an ask written as a bare string (no ref): refused"
bash "$R" page-check "$SAMPLE" >/dev/null; assert_eq "$?" 0 "static mode needs no board, clock or ref and passes the sample"
awk '/RENDER/{f=1} f' "$TPL" | grep -v 'may carry a ref' | grep -qE '\.ref\b' && fail "the render script never reads ref (it is for the check, not the reader)" || pass

# 11) The command and brief carry the rebuild order and name the check.
for m in 'Rebuild every field above the history' 'History last' 'page-check --publish' 'Seeing a check queued is not seeing' 'fork:<ticket>/<fork_id>'; do
  grep -qF "$m" "$CMD" && pass || fail "status.md carries: $m"
done
grep -qF 'Progress-page check' "$SKILL" && pass || fail "SKILL Hooks section names the progress-page check"
