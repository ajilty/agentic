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
  page_on && echo "ledger.sh: progress page is on for this goal; refresh it before this turn ends (/orchestrate:status, or references/status-page-rules.md)" >&2
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  core)       # print the router's core instructions: SKILL.md without its frontmatter, plus
              # where the references live. ONE source for the three ways the core reaches a
              # router: injected by the start command (inside `brief`), re-attached by the
              # post-compaction hook, and loaded as the skill. Must stay under 9,500 characters
              # (hook output is capped at 10,000; tests/test_core_brief.sh holds the line).
    sk="$(cd "$(dirname "$0")/.." && pwd)"
    body="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$sk/SKILL.md" 2>/dev/null | sed '/./,$!d')"
    [ -n "$body" ] || { echo "ledger.sh core: no core instructions found in $sk/SKILL.md" >&2; exit 2; }
    printf '%s\n\nThe references named above are files under %s/references/ (read them by that path).\n' "$body" "$sk" ;;

  brief)      # the core plus the references a run with a writer needs (sizing, dispatching,
              # routing, review rounds, shared targets, landing): what the start command injects.
              # A start has no size cap; the post-compaction hook does, so it carries `core`
              # alone. Injected text must never fail (a failed injection aborts the whole
              # command before the model sees it), so a broken install prints one line saying
              # what to do and exits 0.
    sk="$(cd "$(dirname "$0")/.." && pwd)"
    if ! bash "$0" core 2>/dev/null; then
      echo "ORCHESTRATE: the core instructions could not be printed from $sk. Load the orchestrate skill now and follow it from loop step 1."
      exit 0
    fi
    for n in sizing dispatching routing review-rounds shared-targets landing; do
      printf '\n---\n\n'
      if [ -f "$sk/references/$n.md" ]; then cat "$sk/references/$n.md"
      else echo "ORCHESTRATE: the reference $n could not be printed from $sk/references. Find and read $n.md in the orchestrate skill's references directory before the step that names it."; fi
    done
    exit 0 ;;

  rules)      # print one reference file by name (no extension): `ledger.sh rules status-page-rules`.
              # Also injected by a command, so a missing file prints one line and exits 0;
              # a name that is a path is misuse and exits 2.
    sk="$(cd "$(dirname "$0")/.." && pwd)"; n="${1:?reference name}"
    case "$n" in */*|*..*|-*) echo "ledger.sh rules: a bare reference name, not a path" >&2; exit 2 ;; esac
    if [ -f "$sk/references/$n.md" ]; then cat "$sk/references/$n.md"
    else echo "ORCHESTRATE: the reference $n could not be printed from $sk/references. Find and read $n.md in the orchestrate skill's references directory before going on."; fi ;;

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
    # Escalated dispatches (references/sizing.md) show up as a distinct triple next to the tier default.
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

  decision)   # record a resolved DECISION_FORK or a prod confirmation (references/runtime.md "Judgment memory",
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
    # answer at intake), the ceiling no persona runs above (references/sizing.md).
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

  page-check) # progress-page checks (0.9.6; contract in references/status-page.html).
              #   page-check <file>            the page alone: prose budgets, finish dates that
              #                                disagree, script that does not parse
              #   page-check --publish <file>  plus the page against the board and the clock,
              #                                run before every publish (the publish hook runs it)
              # Prints one line per failure. Exit 1 on any failure, 2 when the page cannot be
              # read at all (fail closed: an unparseable page is not a passing one).
              # Why deterministic: the refresh rules were prose, and on quiet ticks a router
              # bumped the stamp, appended a history line, and left the rest as written the
              # night before (measured 2026-11-09/10). A fresh stamp proved nothing.
    pub=0; if [ "${1:-}" = --publish ]; then pub=1; shift; fi
    f="${1:?page file}"; [ -f "$f" ] || { echo "page-check: no such file: $f" >&2; exit 2; }
    bad=0
    awk '
      function words(x,  n,a){ n=split(x,a,/[ \t]+/); return n - (a[1]=="") - (a[n]=="" && n>1) }
      # A sentence ends at . ! or ? followed by a space and a capital, or at the end of
      # the text; "e.g." and "11 a.m. ET" do not end one.
      function sentences(x,  y,n){ y=x; gsub(/(^|[^A-Za-z])([aApP]\.[mM]|e\.g|i\.e|etc|vs|approx)\./,"",y)
        n=gsub(/[.!?]+ +[A-Z]/,"",y); return n + 1 }
      function report(name,x,maxw,maxs){
        if (words(x) > maxw) { printf "%s: %d words (budget %d): %.60s...\n", name, words(x), maxw, x; bad=1 }
        if (maxs && sentences(x) > maxs) { printf "%s: %d sentences (budget %d)\n", name, sentences(x), maxs; bad=1 }
      }
      # The string value of key on this line; key must start the line or follow { , or
      # a space, so " t:" never matches inside "at:".
      function field(line,key,  re,rest){ re="(^|[{ ,\t])" key ": *\""
        if (!match(line,re)) return "\001"; rest=substr(line,RSTART+RLENGTH-1)
        if (match(rest,/"([^"\\]|\\.)*"/)) return substr(rest,RSTART+1,RLENGTH-2); return "\001" }
      # Every string on this line belongs to the open array; the array closes when what
      # follows the last string contains ].
      function scan(line,  rest){ rest=line
        if (field(rest,"t")!="\001") { cnt++; report(arr" item "cnt, field(rest,"t"), 30, 0); rest="" ; if (line ~ /\][ \t]*,?[ \t]*$/ && line !~ /\}[ \t]*,?[ \t]*$/) rest="]" }
        while (match(rest,/"([^"\\]|\\.)*"/)) { cnt++; report(arr" item "cnt, substr(rest,RSTART+1,RLENGTH-2), arr=="changed"?20:30, 0); rest=substr(rest,RSTART+RLENGTH) }
        if (rest ~ /\]/) { if (arr=="changed" && cnt>5) { printf "changed: %d bullets (budget 5)\n", cnt; bad=1 }; arr="" } }
      /const DATA = \{/ {in_data=1; seen_data=1; next}
      in_data && /^\};/ {in_data=0}
      !in_data {next}
      arr != "" { scan($0); next }
      /^[ \t]*(changed|needs): *\[/ { arr=($0 ~ /changed/) ? "changed" : "needs"; cnt=0
        line=$0; sub(/^[^[]*\[/,"",line); scan(line); next }
      { x=field($0,"headline"); if (x!="\001") { seen_head=1; report("headline", x, 20, 1); next } }
      { x=field($0,"sublead");  if (x!="\001") { report("sublead", x, 40, 2); next } }
      { x=field($0,"d"); if (x!="\001") report("window step", x, 25, 0) }
      { x=field($0,"m"); if (x!="\001") report("stream item", x, 30, 0) }
      { x=field($0,"t"); if (x!="\001") report("made/history entry", x, 25, 0) }
      END {
        if (!seen_data || !seen_head) { print "page-check: no DATA block with a double-quoted headline found; cannot check this page" > "/dev/stderr"; exit 2 }
        exit bad ? 1 : 0 }
    ' "$f" || { rc=$?; [ "$rc" = 2 ] && exit 2; bad=1; }

    # The page script must parse (node when present; the banner and render are code).
    if command -v node >/dev/null 2>&1; then
      jsd="$(mktemp -d "${TMPDIR:-/tmp}/page-check.XXXXXX")"   # node judges a file by its extension
      awk '/<script>/{f=1;next} /<\/script>/{f=0} f' "$f" > "$jsd/page.js"
      node --check "$jsd/page.js" >/dev/null 2>&1 || { echo "script: the page code does not parse (node --check)"; bad=1; }
      rm -rf "$jsd"
    else
      echo "page-check: node not installed; the parse check was skipped" >&2
    fi

    # Board facts for the cross-checks, read in journal order so the LAST word wins: a
    # ticket closed and then dispatched again is open; a fork answered and then raised
    # again is waiting. Field order inside a row is free.
    facts="$(mktemp "${TMPDIR:-/tmp}/page-facts.XXXXXX")"
    if [ "$pub" = 1 ] && [ -f "$LEDGER" ]; then
      awk '
        function j(k,  r){ r="\"" k "\":\"[^\"]*\""; if (match($0,r)) return substr($0,RSTART+length(k)+4,RLENGTH-length(k)-5); return "" }
        { t=j("ticket"); e=j("event"); fk=j("fork_id"); if (t!="") T[t]=1
          if (e=="done") D[t]=1
          if (e=="dispatched" || e=="intake") { D[t]=0; A[t]=0 }          # reopened: earlier done/approval no longer stands
          if (e=="verdict") { if (j("mode")=="plan") { if (j("verdict")=="APPROVED") P[t]=1; else P[t]=0 }
                              else if (j("verdict")=="APPROVED") A[t]=1; else A[t]=0 }
          if (e=="fork" && fk!="") K[t "/" fk]="open"
          if (e=="decision" && fk!="") K[t "/" fk]="decided" }
        END { for (t in T) print "ticket\t" t; for (t in D) if (D[t]) print "done\t" t
              for (t in A) if (A[t]) print "approved\t" t; for (t in P) if (P[t]) print "plan\t" t
              for (k in K) print "fork\t" k "\t" K[k] }' "$LEDGER" > "$facts"
    fi
    awk -v pub="$pub" -v facts="$facts" '
      BEGIN { while ((getline line < facts) > 0) { split(line,a,"\t"); if (a[1]=="fork") K[a[2]]=a[3]; else F[a[1] "\t" a[2]]=1 }   # an empty facts file must not swallow the page
              split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",MON," ")
              MRE="(Jan(uary)?|Feb(ruary)?|Mar(ch)?|Apr(il)?|May|June?|July?|Aug(ust)?|Sep(t(ember)?)?|Oct(ober)?|Nov(ember)?|Dec(ember)?)" }
      function field(line,key,  re,rest){ re="(^|[{ ,\t])" key ": *\""
        if (!match(line,re)) return "\001"; rest=substr(line,RSTART+RLENGTH-1)
        if (match(rest,/"([^"\\]|\\.)*"/)) return substr(rest,RSTART+1,RLENGTH-2); return "\001" }
      function fail(m){ print m; bad=1 }
      # Dates in x, normalised to "Nov 18": "Nov 18", "November 18", "18 Nov", "2026-11-18".
      # A month name must be a whole word ("Decision 4" is not December).
      function dates(x, out,  n,m,y,pad,i,num){ n=0; pad=" " x " "; gsub(/[^A-Za-z0-9-]/," ",pad)
        y=pad; while (match(y," " MRE " [0-9][0-9]? ")) { m=substr(y,RSTART+1,RLENGTH-2); y=substr(y,RSTART+RLENGTH-1)
          num=m; sub(/^[A-Za-z]+ /,"",num); out[++n]=substr(m,1,3) " " (num+0) }
        y=pad; while (match(y," [0-9][0-9]? " MRE " ")) { m=substr(y,RSTART+1,RLENGTH-2); y=substr(y,RSTART+RLENGTH-1)
          num=m; sub(/ .*/,"",num); sub(/^[0-9]+ /,"",m); out[++n]=substr(m,1,3) " " (num+0) }
        y=pad; while (match(y,/ 20[0-9][0-9]-[01][0-9]-[0-3][0-9] /)) { m=substr(y,RSTART+1,10); y=substr(y,RSTART+RLENGTH-1)
          out[++n]=MON[substr(m,6,2)+0] " " (substr(m,9,2)+0) }
        return n }
      # Finish dates a sentence claims: a date in the same clause as a forward-looking
      # finish word. Past tense ("completed Nov 7") is a report, not a claim.
      function claims(where,x,  lx,seg,w,d,n,i){ lx=x
        while (match(tolower(lx),/(target[a-z]*|finish[a-z]*|complet[a-z]*|done by|estimat[a-z]*|due)[^.;]*/)) {
          seg=substr(lx,RSTART,RLENGTH); lx=substr(lx,RSTART+RLENGTH); w=tolower(seg); sub(/[^a-z].*/,"",w)
          if (w ~ /^(finished|completed)$/) continue
          n=dates(seg,d); for (i=1;i<=n;i++) { claim[++nc]=d[i]; cwhere[nc]=where } } }
      function short(x){ return length(x)>50 ? substr(x,1,50) "..." : x }
      # What the journal says about one page entry.
      #   kind ask       listed as waiting on the operator (needs, pending)
      #   kind unstarted shown as not started, or as waiting on the operator (next, you, queued, op)
      #   kind finished  shown as done or live
      #   kind other     in flight, built, or waiting on a date: a done ROW is not proof it is
      #                  live, so merged-but-unproven work may stay here
      function judge(sec,label,ref,kind,shown,  key,t){
        if (ref=="\001" || ref=="") { if (sec!="streams") fail(sec ": \"" short(label) "\" has no ref, so it cannot be checked against the journal"); return }
        if (ref ~ /^none:/) {
          if (kind=="ask") fail(sec ": \"" short(label) "\" is an ask with no decision behind it; journal it as a fork and name it fork:<ticket>/<fork_id>")
          else unver++
          return }
        if (ref ~ /^fork:/) { key=substr(ref,6)
          if (!(key in K)) { fail(sec ": \"" short(label) "\" names a decision the journal does not have (" key ")"); return }
          if (K[key]=="decided" && (kind=="ask" || kind=="unstarted")) fail(sec ": \"" short(label) "\" still waits on the operator, but the journal shows it answered")
          return }
        if (ref ~ /^plan:/) { t=substr(ref,6)
          if (!(("ticket\t" t) in F)) { fail(sec ": \"" short(label) "\" names a ticket the journal does not have (" t ")"); return }
          if (kind=="finished" && !(("plan\t" t) in F)) fail(sec ": \"" short(label) "\" is shown as " shown ", but the journal has no approved plan for " t)
          return }
        if (!(("ticket\t" ref) in F)) { fail(sec ": \"" short(label) "\" names a ticket the journal does not have (" ref ")"); return }
        if (kind=="finished") { if (!(("done\t" ref) in F) && !(("approved\t" ref) in F)) fail(sec ": \"" short(label) "\" is shown as " shown ", but the journal has no done row or approved outcome verdict for " ref) }
        else if ((kind=="ask" || kind=="unstarted") && (("done\t" ref) in F)) fail(sec ": \"" short(label) "\" is shown as " shown ", but the journal records " ref " as done") }
      /const DATA = \{/ {in_data=1; next}
      in_data && /^\};/ {in_data=0}
      !in_data {next}
      { if (match($0,/^[ \t]*[A-Za-z_]+:/)) { k=$0; sub(/^[ \t]*/,"",k); sub(/:.*/,"",k)
          if (k ~ /^(headline|sublead|changed|tiles|needs|window|winTitle|winSub|states|order|streams|made|pending|later|estimate|history|howto|foot|updated|updated_at|cadence_minutes|eyebrow)$/) sec=k } }
      sec=="headline" || sec=="sublead" || sec=="winSub" { x=field($0,sec); if (x!="\001") claims(sec,x) }
      sec=="tiles" { l=field($0,"l"); v=field($0,"v"); if (l!="\001" && tolower(l) ~ /target|finish|complet|done by|estimat|due/ && tolower(l) !~ /(finished|completed)/) { n=dates(v " " l,d); for (i=1;i<=n;i++) { claim[++nc]=d[i]; cwhere[nc]="tiles" } } }
      sec=="estimate" { x=field($0,"complete"); if (x!="\001") { ne=dates(x,EST) } }
      sec=="window" { x=field($0,"name"); if (x!="\001") claims("window",x); x=field($0,"d"); if (x!="\001") claims("window",x) }
      # Every entry on the line is judged, wherever the array opens or closes: objects
      # {..} carry their own ref; a bare string in needs or pending has none.
      pub=="1" && (sec=="needs" || sec=="pending" || sec=="window" || sec=="streams") {
        rest=$0; if (sec=="needs" || sec=="pending") sub(/^[ \t]*(needs|pending):[ \t]*\[?/,"",rest)
        while (match(rest,/\{[^{}]*\}|"([^"\\]|\\.)*"/)) { e=substr(rest,RSTART,RLENGTH); rest=substr(rest,RSTART+RLENGTH)
          if (sec=="needs" || sec=="pending") {
            if (substr(e,1,1)=="{") judge(sec,field(e,"t"),field(e,"ref"),"ask","waiting on the operator")
            else judge(sec,substr(e,2,length(e)-2),"\001","ask","waiting on the operator") }
          else if (substr(e,1,1)=="{" && sec=="window") { st=field(e,"state")
            if (st!="\001") judge(sec,field(e,"name"),field(e,"ref"),(st=="done")?"finished":((st=="next"||st=="you")?"unstarted":"other"),st) }
          else if (substr(e,1,1)=="{" && sec=="streams") { st=field(e,"st"); r=field(e,"ref")
            if (st!="\001" && r!="\001") judge(sec,field(e,"n"),r,(st=="live")?"finished":((st=="queued"||st=="op")?"unstarted":"other"),st) } } }
      END {
        for (i=1;i<=nc;i++) {
          if (!ne) { fail(cwhere[i] ": names " claim[i] " as the finish date, but the estimate card gives no date"); continue }
          ok=0; for (q=1;q<=ne;q++) if (claim[i]==EST[q]) ok=1
          if (!ok) fail(cwhere[i] ": names " claim[i] " as the finish date, but the estimate card says " EST[1] (ne>1 ? " to " EST[ne] : "")) }
        if (pub=="1" && unver) print "note: " unver " entries marked none: cannot be checked against the journal"
        exit bad ? 1 : 0 }
    ' "$f" || bad=1
    rm -f "$facts"

    if [ "$pub" = 1 ]; then
      # The stamp is the real publish time: UTC, not in the future, no older than ten
      # minutes. Minutes are computed in awk (no GNU/BSD date arithmetic to differ on).
      now="${PAGE_CHECK_NOW:-$(date -u +%FT%TZ)}"
      ua="$(sed -n 's/^[[:space:]]*updated_at:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
      case "$ua" in
        20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z)
          age="$(awk -v a="$ua" -v n="$now" '
            function mins(ts,  y,m,d){ y=substr(ts,1,4)+0; m=substr(ts,6,2)+0; d=substr(ts,9,2)+0
              if (m<=2) { y--; m+=12 }                                   # days from civil date
              return (365*y + int(y/4) - int(y/100) + int(y/400) + int((153*(m-3)+2)/5) + d) * 1440 + substr(ts,12,2)*60 + substr(ts,15,2) }
            BEGIN { print mins(n) - mins(a) }')"
          if [ "$age" -lt 0 ]; then echo "updated_at: $ua is in the future (now $now)"; bad=1
          elif [ "$age" -gt 10 ]; then echo "updated_at: $ua is not the publish time (now $now); stamp the page when you publish it, with date -u +%FT%TZ"; bad=1; fi ;;
        *) echo "updated_at: \"$ua\" is not a UTC timestamp from date -u +%FT%TZ"; bad=1 ;;
      esac
      # The stale-top tripwire. Fingerprint everything in DATA except the stamp and the
      # history, whitespace collapsed. If the journal has NEWS since the last passing
      # check (a lane closed, a verdict, a fork raised or answered) and the fingerprint
      # has not moved, only the stamp and history were touched. It catches the lazy
      # refresh that was measured; a refresh that changes one word passes it, so the
      # cross-checks above carry the weight, not this.
      fp="$(awk '/const DATA = \{/{d=1;next} d&&/^\};/{d=0} !d{next}
                 /^[ \t]*(updated|updated_at):/{next}
                 /^[ \t]*history:[ \t]*\[/{h=1} h{ if ($0 ~ /\][ \t]*,?[ \t]*$/) h=0; next }
                 { gsub(/[ \t]+/," "); sub(/^ /,""); sub(/ $/,""); if ($0!="") print }' "$f" | cksum | awk '{print $1}')"
      ev=0; [ -f "$LEDGER" ] && ev="$(grep -E '"event":"(verdict|fork|decision|done)"' "$LEDGER" | grep -vcF '"fork_id":"status-page"' || true)"
      st="$ROOT/status.check"
      if [ -f "$st" ]; then
        read -r ofp oev < "$st" || true
        if [ "${oev:-0}" -lt "$ev" ] && [ "$ofp" = "$fp" ]; then
          echo "stale: the journal has $((ev - ${oev:-0})) new results (lanes closed, verdicts, decisions) since the last checked publish, but nothing on the page changed except the stamp and the history. Rebuild the headline, lead, changed strip, tiles, needs, window, streams and calls from the journal, then add the history line."
          bad=1
        fi
      fi
      # Recorded only on a pass, so a refused page cannot make its own stale state the baseline.
      if [ "$bad" = 0 ]; then mkdir -p "$ROOT"; printf '%s %s\n' "$fp" "$ev" > "$st"; fi
    fi
    exit "$bad" ;;

  *) echo "usage: ledger.sh {core|brief|rules <name>|append '<json>'|retries <ticket>|reground|metrics [ticket]|feedback <note>|conformance <event[:detail]>...|clarify <skill> [ticket]|decision <ticket> <fork_id> [adr] [note]|goal <note> [spec] [base] [main_model]|done <ticket>}" >&2; exit 64 ;;
esac
