#!/usr/bin/env bash
# ledger.sh — harness-agnostic board ledger (the router's durable control state).
# The orchestrator IS the driver: it appends events as it dispatches, and reads
# them back on resume. No deps beyond coreutils/awk/git.
#
#   ledger.sh append '<json-object>'   # one event line (write-ahead before dispatch)
#   ledger.sh retries <ticket>         # COUNT of outcome REJECTED verdict rows (one per round; no-loop budget, derived)
#   ledger.sh reground                 # reconstruct open lanes; reconcile vs this run's git worktrees
#                                       # first archives run-state files no current version reads (0.8.x leases/, active-writer.json)
#                                       # exit 0 = report (act on it), exit 3 = lane worktree the board lost -> HALT
#   ledger.sh goal <note> [spec] [base] [main_model]  # journal the run-level goal (ADR-0020)
# Runs under bash 3.2 (macOS /bin/bash): no associative arrays.
set -euo pipefail
# Anchor the board at the MAIN checkout's root, never the process cwd: hooks fire
# from inside agent worktrees, and appending telemetry to a linked worktree's COPY
# of board.jsonl leaves that tree permanently dirty after squash-merge — reground
# then HALTs on "ambiguous in-flight writer" for lanes that are fully done
# (measured 2026-08-05: 4 false-positive HALTs, each dirty only with denied
# lines). git-common-dir resolves to the main .git from any linked worktree;
# non-git cwd (test fixtures) falls back to the old relative path.
_gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
case "$_gcd" in */.git) _base="${_gcd%/.git}/";; *) _base="";; esac
ROOT="${_base}.agents/runs/orchestrate"; LEDGER="$ROOT/board.jsonl"
val() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<< "$1"; }
# Free text into a JSON string body: escape backslash and quote, turn newline/CR/tab into
# spaces, and drop every other control character (each would make the line invalid JSON).
jtext() { local x="${1//\\/\\\\}"; x="${x//\"/\\\"}"; printf '%s' "$x" | tr '\n\r\t' '   ' | tr -d '\000-\037\177'; }

# Progress-page nudge (0.9.6): when the current goal has an accepted progress page,
# every lane state change reminds the router, on stderr, that the page is due a
# refresh before the turn ends. Stated by the helper the router already calls, so
# the refresh rides the journal write instead of a rule it has to remember.
page_on() { [ -f "$LEDGER" ] && awk '/"event":"goal"/{on=0}
  /"event":"decision"/ && /"fork_id":"status-page"/{on=($0 ~ /"note":"accepted/)}
  END{exit on?0:1}' "$LEDGER"; }
page_nudge() {
  case "$1" in dispatched|returned|verdict|fork|decision|lane|done) ;; *) return 0 ;; esac
  case "${2:-}" in status-page) return 0 ;; esac
  page_on && echo "ledger.sh: progress page is on for this goal; refresh it before this turn ends (/orchestrate:status, Progress page > Refresh)" >&2
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  append)
    # The helper must out-earn `echo >>` or routers bypass it (measured: 311/503
    # field board lines had no ts; only `done`, whose helper does real work, hit
    # 100%). Stamps ts when absent and flags a non-canonical event name — but
    # NEVER drops the line: on an append-only journal a mis-named event beats a
    # lost one.
    mkdir -p "$ROOT"; line="$*"
    case "$line" in
      '{'*'"ts":'*) ;;
      '{'*) line="{\"ts\":\"$(date -u +%FT%TZ)\",${line#?}" ;;
    esac
    ev="$(val "$line" event)"
    case "$ev" in
      goal|intake|clarify|dispatched|returned|verdict|fork|decision|denied|lane|done|feedback) ;;
      *) echo "ledger.sh append: WARNING event '${ev:-<missing>}' is not canonical — invisible to reground/metrics/conformance (vocabulary: references/resume.md)" >&2 ;;
    esac
    # A hand-built goal with the wrong field name is a measured drift ("goal": instead
    # of "note":) that makes the anchor INVISIBLE to reground. Warn; the goal helper
    # gets it right for free.
    if [ "$ev" = goal ]; then case "$line" in *'"note":'*) ;;
      *) echo "ledger.sh append: WARNING goal event without a \"note\" field: reground's goal anchor reads note; use: ledger.sh goal '<note>' [spec] [base]" >&2 ;;
    esac; fi
    printf '%s\n' "$line" >> "$LEDGER"
    page_nudge "$ev" "$(val "$line" fork_id)" ;;

  retries)   # derived, never held: compaction can't corrupt a disk count
    t="${1:?ticket}"; [ -f "$LEDGER" ] || { echo 0; exit 0; }
    # Field-order independent: a hand-appended line may put verdict before ticket. A
    # plan-mode verdict ("mode":"plan") judges the spec, not the implementer's work, so it
    # spends no implementer retry. Three-lens rounds journal ONE verdict row per round.
    grep -F "\"ticket\":\"$t\"" "$LEDGER" | grep -F '"verdict":"REJECTED"' | grep -vcF '"mode":"plan"' || true ;;

  metrics)   # metrics (SKILL.md "Ledger"), derived by replaying the ledger (no separate sink). Optional
             # ticket filter. Emits key=val pairs; splits healthy escalations (forks/
             # decisions) from friction (rejects + oracle-inconsistencies + lease-conflicts).
    t="${1:-}"
    src(){ [ -f "$LEDGER" ] || return 0; if [ -n "$t" ]; then grep "\"ticket\":\"$t\"" "$LEDGER"; else cat "$LEDGER"; fi; }
    c(){ src | grep -c "$1" 2>/dev/null || true; }
    sh=$(c '"event":"done"'); di=$(c '"event":"dispatched"')
    # A prod confirmation (fork_id prod-ack:<target>) is routine, not a hard call: counted
    # as prod_acks, kept out of forks/decisions so those stay the healthy-escalation signal.
    # A progress-page row (fork_id status-page: acceptance, decline, cadence change) is
    # bookkeeping, not an escalation: excluded the same way (0.9.5).
    fk=$(src | grep -F '"event":"fork"' | grep -vF '"fork_id":"prod-ack:' | grep -vcF '"fork_id":"status-page"' 2>/dev/null || true)
    de=$(src | grep -F '"event":"decision"' | grep -vF '"fork_id":"prod-ack:' | grep -vcF '"fork_id":"status-page"' 2>/dev/null || true)
    pa=$(src | grep -F '"event":"decision"' | grep -cF '"fork_id":"prod-ack:' 2>/dev/null || true)
    rj=$(c '"verdict":"REJECTED"'); oi=$(c '"verdict":"INCONSISTENT_ORACLE"')
    lc=$(c '"event":"lease-conflict"'); dn=$(c '"event":"denied"'); fr=$(( rj + oi + lc ))
    # delegation health (the infra-log finding: verification is the least-delegated function).
    dr=$(c '"event":"dispatched".*"persona":"researcher"'); dp=$(c '"event":"dispatched".*"persona":"planner"')
    dimp=$(c '"event":"dispatched".*"persona":"implementer"'); da=$(c '"event":"dispatched".*"persona":"actuator"')
    # Horsepower actually spent (verify optimal usage): persona:model:effort:count over
    # dispatched events that journaled model/effort (optional fields; '-' when absent).
    # Escalated dispatches (SKILL.md "Right-sizing") show up as a distinct triple next to the tier default.
    # `|| true` is load-bearing: with ZERO dispatched events grep exits 1, and under
    # set -euo pipefail that killed metrics (and feedback with it) on a fresh board.
    mix="$(src | grep '"event":"dispatched"' | sed -n 's/.*"persona":"\([^"]*\)".*/\1 &/p' | while read -r p line; do
      m="$(printf '%s' "$line" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')"
      e="$(printf '%s' "$line" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')"
      printf '%s:%s:%s\n' "$p" "${m:--}" "${e:--}"
    done | sort | uniq -c | awk '{print $2":"$1}' | paste -sd, - || true)"; mix="${mix:--}"
    dv=$(src | grep -cE '"event":"dispatched".*"persona":"(verifier|validator)"' 2>/dev/null || true)
    # unjournaled_work: returned/verdict events exceeding dispatched events on the same
    # ticket: personas that ran with no dispatched row, so model_mix cannot attribute
    # their horsepower and the run's cost is undercounted (measured 2026-08-05: planner +
    # verifier ran while model_mix showed nothing). Per-ticket so lanes can't cancel out.
    uw=0
    while IFS= read -r tk; do [ -n "$tk" ] || continue
      w=$(src | grep "\"ticket\":\"$tk\"" | grep -cE '"event":"(returned|verdict)"' 2>/dev/null || true)
      dd=$(src | grep "\"ticket\":\"$tk\"" | grep -c '"event":"dispatched"' 2>/dev/null || true)
      if [ "$w" -gt "$dd" ]; then uw=$((uw + w - dd)); fi
    done < <(src | grep -E '"event":"(returned|verdict)"' | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p' | sort -u)
    # verify_coverage: of shipped (done) lanes, how many got an outcome verdict? Field-order
    # independent, and a plan-mode verdict (the spec, not the change) does not count.
    verified=0; total=0
    while IFS= read -r tk; do [ -n "$tk" ] || continue; total=$((total+1))
      src | grep -F "\"ticket\":\"$tk\"" | grep -F '"event":"verdict"' | grep -vqF '"mode":"plan"' && verified=$((verified+1))
    done < <(src | grep '"event":"done"' | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p' | sort -u)
    printf 'shipped=%s dispatches=%s forks=%s decisions=%s prod_acks=%s rejects=%s oracle_inconsistent=%s lease_conflicts=%s denials=%s friction=%s disp_researcher=%s disp_planner=%s disp_implementer=%s disp_verifier=%s disp_actuator=%s verify_coverage=%s/%s model_mix=%s unjournaled_work=%s\n' \
      "$sh" "$di" "$fk" "$de" "$pa" "$rj" "$oi" "$lc" "$dn" "$fr" "$dr" "$dp" "$dimp" "$dv" "$da" "$verified" "$total" "$mix" "$uw" ;;

  feedback)  # Tier 3c, Layer 3: append a durable operator-feedback record (a ledger
             # metrics snapshot + a free-text rating) to the eval log, and echo it. This
             # is the live, observational complement to the headless A/B (tests/eval).
             # Stamped with the plugin version (ADR-0028) so cross-run trends attribute
             # behavior to releases instead of the operator's memory of "before/after".
    note="${*:-}"; ed="$ROOT/eval"; mkdir -p "$ed"
    pv="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$(cd "$(dirname "$0")/../../.." && pwd)/.claude-plugin/plugin.json" 2>/dev/null | head -1)"; [ -n "$pv" ] || pv="-"
    m="$(bash "$0" metrics)"
    # Quote non-integer values (verify_coverage=1/2, model_mix=...) so the record stays
    # valid JSON; bare integers stay numeric.
    json=""; for kv in $m; do v="${kv#*=}"
      case "$v" in ''|*[!0-9]*) v="\"$v\"" ;; esac
      json="$json,\"${kv%%=*}\":$v"
    done
    nl="$(jtext "$note")"
    printf '{"ts":"%s","event":"feedback","plugin_version":"%s","note":"%s"%s}\n' "$(date -u +%FT%TZ)" "$pv" "$nl" "$json" >> "$ed/feedback.jsonl"
    printf 'feedback recorded -> %s\n%s\nnote: %s\n' "$ed/feedback.jsonl" "$m" "${note:-<none>}" ;;

  conformance)  # Tier 3c trace conformance: assert the ledger contains the expected
                # choreography as an ORDERED SUBSEQUENCE. Each arg is event[:detail],
                # e.g. dispatched:implementer, returned:researcher, verdict, verdict:APPROVED.
                # Catches orchestrate silently SKIPPING a step (e.g. the verifier never
                # ran -> no verdict). exit 0 = chain ran as designed; exit 1 = first unmet
                # step named; exit 64 = no specs.
    [ $# -gt 0 ] || { echo "usage: ledger.sh conformance <event[:detail]>..." >&2; exit 64; }
    specs=("$@"); n=$#; i=0
    if [ -f "$LEDGER" ]; then
      while IFS= read -r line; do
        [ "$i" -lt "$n" ] || break
        spec="${specs[$i]}"; kind="${spec%%:*}"; detail=""
        case "$spec" in *:*) detail="${spec#*:}";; esac
        case "$line" in *"\"event\":\"$kind\""*) ;; *) continue;; esac
        if [ -n "$detail" ]; then case "$line" in *"\"$detail\""*) ;; *) continue;; esac; fi
        i=$((i+1))
      done < "$LEDGER"
    fi
    [ "$i" -ge "$n" ] && exit 0
    echo "conformance: chain broke at step $((i+1))/$n — missing (or out of order): ${specs[$i]}" >&2
    exit 1 ;;

  reground)
    # Legacy run state: 0.8.x kept a writer lease and target leases on disk. Nothing reads
    # them since 0.9.0, but a leftover copy reads to a human or an agent as a live
    # single-writer limit (measured 2026-11-06). Archive, never delete, and say so once.
    # Never a failure path: an unwritable run dir or a second session that already
    # moved the files leaves reground's report intact (a non-zero exit here would
    # read as a HALT after compaction). Only the mover announces.
    legacy=""
    for f in active-writer.json leases "$ROOT"/tickets/*/lease "$ROOT"/tickets/*/ack-*; do
      case "$f" in "$ROOT"/*) [ -e "$f" ] && legacy="$legacy ${f#"$ROOT/"}" ;; *) [ -e "$ROOT/$f" ] && legacy="$legacy $f" ;; esac
    done
    if [ -n "$legacy" ]; then
      dest="$ROOT/legacy/$(date -u +%Y%m%dT%H%M%SZ)"; moved=""
      if mkdir -p "$dest" 2>/dev/null; then
        for f in $legacy; do
          case "$f" in */*) mkdir -p "$dest/${f%/*}" 2>/dev/null || continue ;; esac
          mv "$ROOT/$f" "$dest/$f" 2>/dev/null && moved="$moved $f"
        done
      fi
      [ -n "$moved" ] && echo "LEGACY STATE: moved${moved} to ${dest#"$_base"} (written by orchestrate 0.8.x; no current version reads them, so they carry no writer limit; delete the folder when convenient)"
      rmdir "$dest" 2>/dev/null || true
    fi
    # bash 3.2 safe (macOS /bin/bash): no associative arrays. One awk pass over the board
    # prints a T row per ticket (has-dispatched flag + its last lane event) and a B row per
    # branch the board names; the worktree scan then judges only trees this run knows.
    rows=""
    [ -f "$LEDGER" ] && rows="$(awk '
      function f(k,   m) { if (match($0, "\"" k "\":\"[^\"]*\"")) { m = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", m); sub("\"$", "", m); return m } return "" }
      {
        t = f("ticket"); e = f("event"); if (t == "" || e == "") next
        if (e !~ /^(intake|clarify|dispatched|returned|verdict|fork|decision|lane|done)$/) next
        b = f("branch"); if (b != "" && e ~ /^(dispatched|returned|lane)$/) print "B|" b "|" t
        if (!(t in seen)) { seen[t] = 1; order[++n] = t }
        if (e == "dispatched") disp[t] = 1
        last[t] = e "|" f("persona") "|" b "|" f("slug") "|" f("verdict") "|" f("state") "|" f("mode")
      }
      END { for (i = 1; i <= n; i++) { t = order[i]; print "T|" t "|" ((t in disp) ? 1 : 0) "|" last[t] } }' "$LEDGER")"
    ambiguous=0; printed=0; tickets=""
    # (a) ledger intent: every ticket whose lane is not closed, by its last event
    while IFS='|' read -r kind t hasd ev persona branch slug verdict state mode; do
      [ "$kind" = T ] || continue
      tickets="$tickets $t"
      [ "$t" = intake ] && continue          # pre-ticket clarify rows are not a lane
      case "$ev" in done) continue ;; lane) [ "$state" = closed ] && continue ;; esac
      printed=1
      case "$ev" in
        dispatched)
          case "$persona" in
            actuator)
              echo "OPEN WRITER   ticket=$t persona=actuator -> in flight or crashed; never re-dispatch an actuator without confirming with the operator" ;;
            implementer)
              if [ -z "$branch" ]; then
                echo "OPEN WRITER   ticket=$t persona=implementer branch=unknown -> in flight or crashed; before any re-dispatch, match each unclaimed worktree by this ticket id in its commit subjects (git -C <path> log --oneline origin/<base>..HEAD): a match may hold this writer's commits (adopt them, or ask the operator)"
              elif git rev-parse --verify -q "$branch" >/dev/null 2>&1; then
                echo "OPEN WRITER   ticket=$t persona=implementer branch=$branch -> in flight or crashed; reconcile that branch before any re-dispatch"
              else
                echo "OPEN WRITER   ticket=$t persona=implementer branch=$branch MISSING -> re-dispatch candidate"
              fi ;;
            *)
              # READ-ONLY lane (ADR-0014): the re-dispatch decision keys on the promoted
              # result's presence on disk; re-running a reader is idempotent.
              art="$ROOT/tickets/$t/findings/$slug.md"
              if [ -n "$slug" ] && [ -f "$art" ]; then
                echo "READONLY DONE  ticket=$t slug=$slug -> result on disk: $art"
              else
                echo "OPEN READONLY  ticket=$t persona=${persona:-?} slug=${slug:-?} -> re-dispatch (no result on disk${slug:+: $art})"
              fi ;;
          esac ;;
        returned) echo "OPEN LANE     ticket=$t last=returned persona=${persona:-?} -> route its result (a writer's goes to the verifier)" ;;
        verdict)
          if [ "$mode" = plan ]; then
            case "$verdict" in
              APPROVED) echo "OPEN LANE     ticket=$t last=plan-verdict:APPROVED -> spec signed; dispatch the implementers" ;;
              *) echo "OPEN LANE     ticket=$t last=plan-verdict:${verdict:-?} -> back to the planner" ;;
            esac
          else
            case "$verdict" in
              APPROVED) echo "OPEN LANE     ticket=$t last=verdict:APPROVED -> awaiting landing" ;;
              REJECTED) echo "OPEN LANE     ticket=$t last=verdict:REJECTED -> awaiting fix (ledger.sh retries $t)" ;;
              *) echo "OPEN LANE     ticket=$t last=verdict:${verdict:-?} -> the operator" ;;
            esac
          fi ;;
        fork)     echo "OPEN LANE     ticket=$t last=fork -> halted, awaiting the operator" ;;
        intake)   echo "OPEN LANE     ticket=$t last=intake -> not yet dispatched" ;;
        clarify)  echo "OPEN LANE     ticket=$t last=clarify -> clarification open" ;;
        decision) echo "OPEN LANE     ticket=$t last=decision -> decision recorded; resume the lane" ;;
        *)        echo "OPEN LANE     ticket=$t last=$ev -> reconcile" ;;
      esac
    done <<< "$rows"
    # (b) disk ground truth, scoped to this run: a worktree is a lane of this run when its
    #     branch is named on a dispatched/returned/lane row, or it lives under
    #     .claude/worktrees/ or .agents/worktrees/ on a branch naming a ticket on the board.
    #     Other worktrees belong to other sessions: counted once, never judged.
    other=0
    if git rev-parse --git-dir >/dev/null 2>&1; then
      while IFS='|' read -r wt br; do
        [ -n "$br" ] || continue
        kt="$(printf '%s\n' "$rows" | awk -F'|' -v b="$br" '$1 == "B" && $2 == b { t = $3 } END { print t }')"
        if [ -z "$kt" ]; then
          case "$wt" in
            */.claude/worktrees/*|*/.agents/worktrees/*)
              nb="-$(printf '%s' "$br" | tr '/_.' '---')-"
              for t in $tickets; do
                [ "$t" = intake ] && continue
                case "$nb" in *"-$(printf '%s' "$t" | tr '/_.' '---')-"*) kt="$t"; break ;; esac
              done ;;
          esac
        fi
        dirt="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
        # board.jsonl-only dirt is hook-telemetry RESIDUE (pre-0.8.25 hooks appended to the
        # worktree's own board copy), not writer work, in any tree: report, never halt.
        if [ -n "$dirt" ] && [ -z "$(printf '%s\n' "$dirt" | grep -v '\.agents/runs/orchestrate/board\.jsonl$' || true)" ]; then
          echo "TELEMETRY RESIDUE $wt ($br) -> board.jsonl-only dirt, not writer work; safe to discard"; printed=1; continue
        fi
        # orchestrate's own lane naming (worktree-agent-*) that no board row names, with
        # uncommitted work: the ledger lost a writer. HALT; harness-named worktree-* trees stay "other".
        if [ -z "$kt" ] && [ -n "$dirt" ]; then
          case "$br" in
            worktree-agent-*) echo "UNJOURNALED WRITER $wt ($br) -> orchestrate-named tree with no ledger row; reconcile before dispatching"; printed=1; ambiguous=1; continue ;;
          esac
        fi
        [ -n "$kt" ] || { other=$((other + 1)); continue; }
        [ -n "$dirt" ] || continue
        printed=1
        if [ "$(printf '%s\n' "$rows" | awk -F'|' -v t="$kt" '$1 == "T" && $2 == t { print $3 }')" = 1 ]; then
          echo "DIRTY WORKTREE $wt ($br) ticket=$kt -> in flight or crashed; confirm before re-dispatch"
        else
          echo "DIRTY WORKTREE $wt ($br) ticket=$kt -> uncommitted work and no dispatched row on the board (the ledger lost it); show the operator"; ambiguous=1
        fi
      done < <(git worktree list --porcelain 2>/dev/null | awk '
        /^worktree /{ sub(/^worktree /, ""); p = $0; n++ } /^branch /{ b = $2; sub("refs/heads/", "", b); if (n > 1) print p "|" b }')
      [ "$other" -gt 0 ] && echo "OTHER WORKTREES (not this run): $other"
    fi
    # Run-level anchor (ADR-0020): the latest `goal` event carries the north star + a
    # pointer to where the plan durably lives (spec/ADR). Surface it so a clean board
    # never reads as "finished" and resume doesn't depend on external prose.
    gline=""; [ -f "$LEDGER" ] && gline="$(grep '"event":"goal"' "$LEDGER" 2>/dev/null | tail -1 || true)"
    if [ -n "$gline" ]; then
      gn="$(val "$gline" note)"; gs="$(val "$gline" spec)"
      echo "GOAL: ${gn:-?}${gs:+ -> resume from plan: $gs}"
    fi
    [ "$printed" = 0 ] && echo "board: no open lanes${gline:+ (goal above is open unless the plan is complete: verify before concluding done)}"
    [ "$ambiguous" = 1 ] && { echo "REGROUND: lane worktree with no dispatched row -> HALT: show the operator before dispatching"; exit 3; }
    echo "REGROUND: clean" ;;

  decision)   # record a resolved DECISION_FORK or a prod confirmation (SKILL.md "Judgment memory",
              # "Production changes"). The optional note carries the operator's answer, so a
              # prod "declined" never reads like an "approved": decision T prod-ack:<target> "" "approved: ..."
    tk="${1:?ticket}"; fid="${2:?fork_id}"; adr="${3:-}"; note="${4:-}"; mkdir -p "$ROOT"
    nl=""; if [ -n "$note" ]; then nl=",\"note\":\"$(jtext "$note")\""; fi
    printf '{"ts":"%s","ticket":"%s","event":"decision","fork_id":"%s","adr":"%s"%s}\n' "$(date -u +%FT%TZ)" "$tk" "$fid" "$adr" "$nl" >> "$LEDGER"
    page_nudge decision "$fid" ;;

  clarify)    # journal the router's intake-clarification decision (SKILL.md loop step 3, ADR-0004): which
              # clarification skill was selected (first-present-wins), so the choreography
              # is a checkable trace instead of invisible router-context behavior.
    sk="${1:?skill}"; tk="${2:-intake}"; mkdir -p "$ROOT"
    printf '{"ts":"%s","ticket":"%s","event":"clarify","skill":"%s"}\n' "$(date -u +%FT%TZ)" "$tk" "$sk" >> "$LEDGER" ;;

  goal)       # journal a run-level goal + a pointer to where the plan durably lives
              # (spec/ADR). The board records per-ticket lanes (what happened) but nothing
              # run-level, so a CLEAN board (no open lanes, or between phases) loses the
              # north star + next-step location across compaction — resume then depends on
              # an external prose doc. This event anchors the board to the goal (ADR-0020).
              # Run-level, so no ticket field (reground's lane loop skips no-ticket lines).
    # main_model: the router's own model (its system-prompt identity, or the operator's
    # answer at intake), the ceiling no persona runs above (SKILL.md "Right-sizing").
    note="${1:?goal note}"; spec="${2:-}"; base="${3:-}"; mm="${4:-}"; mkdir -p "$ROOT"
    printf '{"ts":"%s","event":"goal","note":"%s","spec":"%s","base":"%s"%s}\n' \
      "$(date -u +%FT%TZ)" "$(jtext "$note")" "$spec" "$base" "${mm:+,\"main_model\":\"$(jtext "$mm")\"}" >> "$LEDGER" ;;

  done)       # close a lane. Verification is guidance, not a gate: a non-T0 lane with no
              # verdict still closes, with a stderr warning; verify_coverage in `metrics`
              # is the retrospective signal. T0 (the oracle is the check) never warns.
    tk="${1:?ticket}"; mkdir -p "$ROOT"; tier=""; hv=0
    if [ -f "$LEDGER" ]; then
      # Field-order independent: match the ticket and the event with separate greps (a
      # hand-appended line may put event before ticket), then extract the field.
      tl="$(grep -F "\"ticket\":\"$tk\"" "$LEDGER" 2>/dev/null || true)"
      tier="$(printf '%s\n' "$tl" | grep -F '"event":"intake"' | sed -n 's/.*"tier":"\([^"]*\)".*/\1/p' | tail -1 || true)"
      printf '%s\n' "$tl" | grep -F '"event":"verdict"' | grep -vqF '"mode":"plan"' && hv=1 || true
    fi
    case "$tier" in
      T0*|t0*) ;;
      *) [ "$hv" = 1 ] || echo "orchestrate: warning: $tk closed without a Verifier verdict (tier=${tier:-unknown}); verify_coverage will show the gap" >&2 ;;
    esac
    printf '{"ts":"%s","ticket":"%s","event":"done"}\n' "$(date -u +%FT%TZ)" "$tk" >> "$LEDGER"
    page_nudge done ;;

  page-check) # progress-page prose budgets (0.9.6; contract in references/status-page.html).
              # Reads the DATA block of a filled page and prints each field over budget;
              # exit 1 if any. Pages grow into walls of text when each refresh extends the
              # last one's prose; a deterministic count is the pushback a rule alone is not.
    f="${1:?page file}"; [ -f "$f" ] || { echo "page-check: no such file: $f" >&2; exit 2; }
    awk '
      function words(x,  n,a){ n=split(x,a,/[ \t]+/); return n - (a[1]=="") - (a[n]=="" && n>1) }
      function sentences(x,  y,n){ y=x; n=gsub(/[.!?]( |$)/,"",y); return n ? n : 1 }
      function report(name,x,maxw,maxs){
        if (words(x) > maxw) { printf "%s: %d words (budget %d): %.60s...\n", name, words(x), maxw, x; bad=1 }
        if (maxs && sentences(x) > maxs) { printf "%s: %d sentences (budget %d)\n", name, sentences(x), maxs; bad=1 }
      }
      function str(line,  m){ if (match(line,/"([^"\\]|\\.)*"/)) return substr(line,RSTART+1,RLENGTH-2); return "" }
      function field(line,key,  i,rest){ i=index(line, key ": \""); if (!i) return ""; rest=substr(line,i+length(key)+2); return str(rest) }
      /const DATA = \{/ {in_data=1; next}
      in_data && /^\};/ {in_data=0}
      !in_data {next}
      /^  headline: "/ {report("headline", field($0,"headline"), 20, 1)}
      /^  sublead: "/  {report("sublead",  field($0,"sublead"), 40, 2)}
      /^  (changed|needs): \[/ { arr=($0 ~ /changed/) ? "changed" : "needs"; cnt=0
        rest=$0; sub(/^[^[]*\[/,"",rest)
        while (match(rest,/"([^"\\]|\\.)*"/)) { cnt++; report(arr" item "cnt, substr(rest,RSTART+1,RLENGTH-2), arr=="changed"?20:30, 0); rest=substr(rest,RSTART+RLENGTH) }
        if ($0 !~ /\]/) { inarr=arr; next } else { if (arr=="changed" && cnt>5) { printf "changed: %d bullets (budget 5)\n", cnt; bad=1 } ; next } }
      inarr != "" {
        if ($0 ~ /^ *\]/) { if (inarr=="changed" && cnt>5) { printf "changed: %d bullets (budget 5)\n", cnt; bad=1 }; inarr=""; next }
        x=str($0); if (x!="") { cnt++; report(inarr" item "cnt, x, inarr=="changed"?20:30, 0) }; next }
      index($0," d: \"")  {report("window step", field($0,"d"), 25, 0)}
      index($0," m: \"")  {report("stream item", field($0,"m"), 30, 0)}
      index($0," t: \"")  {report("made/history entry", field($0,"t"), 25, 0)}
      END { exit bad ? 1 : 0 }
    ' "$f" ;;

  *) echo "usage: ledger.sh {append '<json>'|retries <ticket>|reground|metrics [ticket]|feedback <note>|conformance <event[:detail]>...|clarify <skill> [ticket]|decision <ticket> <fork_id> [adr] [note]|goal <note> [spec] [base] [main_model]|done <ticket>}" >&2; exit 64 ;;
esac
