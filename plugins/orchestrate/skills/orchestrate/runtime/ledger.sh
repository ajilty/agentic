#!/usr/bin/env bash
# ledger.sh — harness-agnostic board ledger (the router's durable control state).
# The orchestrator IS the driver: it appends events as it dispatches, and reads
# them back on resume. No deps beyond coreutils/awk/git.
#
#   ledger.sh append '<json-object>'   # one event line (write-ahead before dispatch)
#   ledger.sh retries <ticket>         # COUNT of REJECTED verdicts for a ticket (no-loop budget, derived)
#   ledger.sh reground                 # reconstruct open lanes; reconcile vs git worktrees (ground truth)
#                                       # exit 0 = clean/empty, exit 3 = ambiguous writer -> HALT
#   ledger.sh goal <note> [spec-path]  # journal the run-level goal + a pointer to the plan (ADR-0020)
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
LEASES="$ROOT/leases"
enc(){ printf '%s' "$1" | sed 's#/#%2F#g'; }   # only '/' needs encoding on Linux
val() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" <<< "$1"; }

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
      goal|intake|clarify|dispatched|returned|verdict|fork|decision|lease-conflict|gate-blocked|denied|lane|done|feedback) ;;
      *) echo "ledger.sh append: WARNING event '${ev:-<missing>}' is not canonical — invisible to reground/metrics/conformance (vocabulary: references/resume.md)" >&2 ;;
    esac
    # A hand-built goal with the wrong field name is a measured drift ("goal": instead
    # of "note":) that makes the anchor INVISIBLE to reground. Warn; the goal helper
    # gets it right for free.
    if [ "$ev" = goal ]; then case "$line" in *'"note":'*) ;;
      *) echo "ledger.sh append: WARNING goal event without a \"note\" field — reground's goal anchor reads note (use: ledger.sh goal '<note>' [spec] [base] [policy])" >&2 ;;
    esac; fi
    printf '%s\n' "$line" >> "$LEDGER" ;;

  retries)   # derived, never held: compaction can't corrupt a disk count
    t="${1:?ticket}"; [ -f "$LEDGER" ] || { echo 0; exit 0; }
    grep -c "\"ticket\":\"$t\".*\"verdict\":\"REJECTED\"" "$LEDGER" || true ;;

  metrics)   # §8 metrics, derived by replaying the ledger (no separate sink). Optional
             # ticket filter. Emits key=val pairs; splits healthy escalations (forks/
             # decisions) from friction (rejects + oracle-inconsistencies + lease-conflicts).
    t="${1:-}"
    src(){ [ -f "$LEDGER" ] || return 0; if [ -n "$t" ]; then grep "\"ticket\":\"$t\"" "$LEDGER"; else cat "$LEDGER"; fi; }
    c(){ src | grep -c "$1" 2>/dev/null || true; }
    sh=$(c '"event":"done"'); di=$(c '"event":"dispatched"'); fk=$(c '"event":"fork"')
    de=$(c '"event":"decision"'); rj=$(c '"verdict":"REJECTED"'); oi=$(c '"verdict":"INCONSISTENT_ORACLE"')
    lc=$(c '"event":"lease-conflict"'); dn=$(c '"event":"denied"'); fr=$(( rj + oi + lc ))
    # delegation health (the infra-log finding: verification is the least-delegated function).
    dr=$(c '"event":"dispatched".*"persona":"researcher"'); dp=$(c '"event":"dispatched".*"persona":"planner"')
    dimp=$(c '"event":"dispatched".*"persona":"implementer"'); da=$(c '"event":"dispatched".*"persona":"actuator"')
    # Horsepower actually spent (verify optimal usage): persona:model:effort:count over
    # dispatched events that journaled model/effort (optional fields; '-' when absent).
    # Escalated dispatches (§2a′) show up as a distinct triple next to the tier default.
    # `|| true` is load-bearing: with ZERO dispatched events grep exits 1, and under
    # set -euo pipefail that killed metrics (and feedback with it) on a fresh board.
    mix="$(src | grep '"event":"dispatched"' | sed -n 's/.*"persona":"\([^"]*\)".*/\1 &/p' | while read -r p line; do
      m="$(printf '%s' "$line" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')"
      e="$(printf '%s' "$line" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')"
      printf '%s:%s:%s\n' "$p" "${m:--}" "${e:--}"
    done | sort | uniq -c | awk '{print $2":"$1}' | paste -sd, - || true)"; mix="${mix:--}"
    dv=$(src | grep -cE '"event":"dispatched".*"persona":"(verifier|validator)"' 2>/dev/null || true)
    # unjournaled_work: returned/verdict events exceeding dispatched events on the same
    # ticket. Those personas ran with NO model bound at dispatch — under the frontmatter
    # bug (#44385) they inherit the main-loop model, so the run's priciest tier does
    # mechanical work invisibly (measured 2026-08-05: planner + verifier rode a flagship
    # main loop while model_mix showed nothing). Per-ticket so lanes can't cancel out.
    uw=0
    while IFS= read -r tk; do [ -n "$tk" ] || continue
      w=$(src | grep "\"ticket\":\"$tk\"" | grep -cE '"event":"(returned|verdict)"' 2>/dev/null || true)
      dd=$(src | grep "\"ticket\":\"$tk\"" | grep -c '"event":"dispatched"' 2>/dev/null || true)
      if [ "$w" -gt "$dd" ]; then uw=$((uw + w - dd)); fi
    done < <(src | grep -E '"event":"(returned|verdict)"' | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p' | sort -u)
    # verify_coverage: of shipped (done) lanes, how many actually got a verifier verdict?
    verified=0; total=0
    while IFS= read -r tk; do [ -n "$tk" ] || continue; total=$((total+1))
      src | grep -q "\"ticket\":\"$tk\".*\"event\":\"verdict\"" && verified=$((verified+1))
    done < <(src | grep '"event":"done"' | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p' | sort -u)
    printf 'shipped=%s dispatches=%s forks=%s decisions=%s rejects=%s oracle_inconsistent=%s lease_conflicts=%s denials=%s friction=%s disp_researcher=%s disp_planner=%s disp_implementer=%s disp_verifier=%s disp_actuator=%s verify_coverage=%s/%s model_mix=%s unjournaled_work=%s\n' \
      "$sh" "$di" "$fk" "$de" "$rj" "$oi" "$lc" "$dn" "$fr" "$dr" "$dp" "$dimp" "$dv" "$da" "$verified" "$total" "$mix" "$uw" ;;

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
    nl="${note//\\/\\\\}"; nl="${nl//\"/\\\"}"
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
    declare -A laststate
    if [ -f "$LEDGER" ]; then
      while IFS= read -r line; do
        t="$(val "$line" ticket)"; [ -z "$t" ] && continue
        ev="$(val "$line" event)"; [ -n "$ev" ] && laststate["$t"]="$ev|$(val "$line" persona)|$(val "$line" branch)|$(val "$line" slug)"
      done < "$LEDGER"
    fi
    ambiguous=0; printed=0
    # (a) ledger-derived open lanes
    for t in "${!laststate[@]}"; do
      IFS='|' read -r ev persona branch slug <<< "${laststate[$t]}"
      [ "$ev" = dispatched ] || continue
      printed=1
      if [ "$persona" = implementer ]; then
        if git rev-parse --verify "$branch" >/dev/null 2>&1; then
          echo "OPEN WRITER   ticket=$t branch=$branch -> reconcile worktree before re-dispatch"; ambiguous=1
        else
          echo "OPEN WRITER   ticket=$t branch=$branch MISSING -> re-dispatch candidate"
        fi
      else
        # READ-ONLY lane (ADR-0014): the result is now a durable file, so the
        # re-dispatch decision keys on its PRESENCE, not a guess. A read-only
        # re-dispatch is idempotent (no writer lease) -> never an ambiguous HALT.
        art="$ROOT/tickets/$t/findings/$slug.md"
        if [ -n "$slug" ] && [ -f "$art" ]; then
          echo "READONLY DONE  ticket=$t slug=$slug -> result on disk: $art"
        else
          echo "OPEN READONLY  ticket=$t persona=$persona slug=${slug:-?} -> re-dispatch (no result on disk${slug:+: $art})"
        fi
      fi
    done
    # (b) disk ground truth: any worktree on a worktree-agent-* branch with
    #     uncommitted work, even if no ledger event exists (missed append / crash).
    if git rev-parse --git-dir >/dev/null 2>&1; then
      while IFS=$'\t' read -r wt br; do
        case "$br" in *worktree-agent-*)
          dirt="$(git -C "$wt" status --porcelain 2>/dev/null)"
          if [ -n "$dirt" ]; then
            # board.jsonl-only dirt is hook-telemetry RESIDUE (pre-0.8.25 hooks
            # appended denied events to the worktree's own board copy), not
            # in-flight work — report it, don't HALT (2026-08-05: 4 false HALTs).
            if [ -z "$(printf '%s\n' "$dirt" | grep -v '\.agents/runs/orchestrate/board\.jsonl$')" ]; then
              echo "TELEMETRY RESIDUE $wt ($br) -> board.jsonl-only dirt, not writer work; safe to discard"; printed=1
            else
              echo "DIRTY WORKTREE $wt ($br) -> uncommitted writer work; reconcile before re-dispatch"; ambiguous=1; printed=1
            fi
          fi ;;
        esac
      done < <(git worktree list --porcelain 2>/dev/null | awk '
        /^worktree /{p=$2} /^branch /{b=$2; sub("refs/heads/","",b); print p"\t"b}')
    fi
    # (c) target leases: reconcile — release a done ticket's lease (so it can't
    #     block a later ticket on the same target); HALT on a lease whose ticket
    #     never reached 'done' (crashed/in-flight), fail-closed.
    if [ -d "$LEASES" ]; then
      for f in "$LEASES"/*; do
        [ -e "$f" ] || continue
        lt="$(val "$(cat "$f")" ticket)"; lk="$(val "$(cat "$f")" key)"
        done_evt=0
        if [ -f "$LEDGER" ]; then grep -q "\"ticket\":\"$lt\".*\"event\":\"done\"" "$LEDGER" && done_evt=1; fi
        [ "$done_evt" = 1 ] && { rm -f "$f"; continue; }   # reconcile: release the done ticket's lease
        echo "OPEN LEASE $lk ticket=$lt -> release or reconcile before re-dispatch"; ambiguous=1; printed=1
      done
    fi
    # (d) dangling active-writer record (ADR-0006): a writer that did not cleanly
    #     close (router crashed between writer-ctx set and clear). A stale record
    #     can let a later dispatch read an already-acked context and bypass the
    #     pre-apply gate, so treat it as an ambiguous in-flight writer and HALT for
    #     reconcile (the operator/router clears it via `writer-ctx clear`). We do
    #     NOT auto-clear: at compaction the record may belong to a live writer.
    #     One record per persona (ADR-0039); each is surfaced on its own. A legacy
    #     single-slot file left by a pre-0.8.29 plugin is never read as context but
    #     still HALTs, so an upgrade mid-run cannot silently drop a writer.
    for awf in "$ROOT"/active-writer.*.json; do
      [ -f "$awf" ] || continue
      awt="$(sed -n 's/^ticket=//p' "$awf")"; awp="${awf##*/active-writer.}"; awp="${awp%.json}"
      echo "OPEN WRITER   active-writer ticket=$awt persona=$awp -> reconcile (ledger.sh writer-ctx clear $awp) before re-dispatch"
      ambiguous=1; printed=1
    done
    if [ -f "$ROOT/active-writer.json" ]; then
      awt="$(sed -n 's/^ticket=//p' "$ROOT/active-writer.json")"
      echo "OPEN WRITER   legacy single-slot active-writer.json ticket=$awt (pre-0.8.29; not read by hooks) -> reconcile (ledger.sh writer-ctx clear) before re-dispatch"
      ambiguous=1; printed=1
    fi
    # Run-level anchor (ADR-0020): the latest `goal` event carries the north star + a
    # pointer to where the plan durably lives (spec/ADR). Surface it so a clean board
    # never reads as "finished" and resume doesn't depend on external prose.
    gline=""; [ -f "$LEDGER" ] && gline="$(grep '"event":"goal"' "$LEDGER" 2>/dev/null | tail -1 || true)"
    if [ -n "$gline" ]; then
      gn="$(val "$gline" note)"; gs="$(val "$gline" spec)"; gp="$(val "$gline" model_policy)"
      echo "GOAL: ${gn:-?}${gs:+ -> resume from plan: $gs}${gp:+ [models: $gp]}"
    fi
    [ "$printed" = 0 ] && echo "board: no open lanes${gline:+ (goal above is open unless the plan is complete — verify before concluding done)}"
    [ "$ambiguous" = 1 ] && { echo "REGROUND: ambiguous writer lane(s) -> HALT for human re-attach"; exit 3; }
    echo "REGROUND: clean" ;;

  lease-key) printf '%s\n' "$(enc "${1:?key}")" ;;

  lease-acquire)   # exit 0 if free or self-owned, 4 if held by another ticket
    tk="${1:?ticket}"; key="${2:?key}"; f="$LEASES/$(enc "$key")"
    mkdir -p "$LEASES"
    if [ -f "$f" ]; then
      owner="$(val "$(cat "$f")" ticket)"
      [ "$owner" = "$tk" ] && exit 0 || exit 4
    fi
    printf '{"key":"%s","ticket":"%s","ts":"%s"}\n' "$key" "$tk" "$(date -u +%FT%TZ)" > "$f" ;;

  lease-release) key="${1:?key}"; rm -f "$LEASES/$(enc "$key")" ;;

  lease-check)   key="${1:?key}"; [ -f "$LEASES/$(enc "$key")" ] && exit 4 || exit 0 ;;

  ack)   # operator confirms a prod-level mutation target for a ticket (pre-apply gate, SKILL §6b)
    tk="${1:?ticket}"; key="${2:?key}"; m="$ROOT/tickets/$tk/ack-$(enc "$key")"
    mkdir -p "$(dirname "$m")"; : > "$m" ;;

  decision)   # record a resolved DECISION_FORK to the board (judgment-memory capture, SKILL §11)
    tk="${1:?ticket}"; fid="${2:?fork_id}"; adr="${3:-}"; mkdir -p "$ROOT"
    printf '{"ts":"%s","ticket":"%s","event":"decision","fork_id":"%s","adr":"%s"}\n' "$(date -u +%FT%TZ)" "$tk" "$fid" "$adr" >> "$LEDGER" ;;

  clarify)    # journal the router's intake-clarification decision (§2b/ADR-0004): which
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
    note="${1:?goal note}"; spec="${2:-}"; base="${3:-}"; pol="${4:-}"; mkdir -p "$ROOT"
    nl="${note//\\/\\\\}"; nl="${nl//\"/\\\"}"          # escape backslash + quote in free text
    # model_policy (ADR-0033): dynamic (default, §2a′ tier table) | quick (dynamic,
    # lean cheaper/faster) | inherit (subagents run the main loop's model/effort).
    # Rides the goal anchor: latest goal wins on reground, survives compaction.
    printf '{"ts":"%s","event":"goal","note":"%s","spec":"%s","base":"%s"%s}\n' \
      "$(date -u +%FT%TZ)" "$nl" "$spec" "$base" "${pol:+,\"model_policy\":\"$pol\"}" >> "$LEDGER" ;;

  done)       # close a lane FAIL-CLOSED on unverified ships: a verifying tier (T1/T2)
              # may not be marked done without a verdict for that ticket. T0 (one
              # Implementer vs the oracle — the oracle IS the check) is exempt; unknown
              # tier requires a verdict (fail-closed). The ENFORCEMENT half of
              # "verification is not optional" — the router under-delegates verification,
              # so the gate makes a ship without a Verifier impossible, not just discouraged.
    tk="${1:?ticket}"; mkdir -p "$ROOT"; tier=""; hv=0
    if [ -f "$LEDGER" ]; then
      # match the ticket and the event as separate fields: JSON field order is not
      # fixed (a verdict journaled event-first was refused as missing, 2026-11-06)
      tier="$(grep "\"ticket\":\"$tk\"" "$LEDGER" 2>/dev/null | grep '"event":"intake"' | sed -n 's/.*"tier":"\([^"]*\)".*/\1/p' | tail -1 || true)"
      grep "\"ticket\":\"$tk\"" "$LEDGER" 2>/dev/null | grep -q '"event":"verdict"' && hv=1 || true
    fi
    case "$tier" in
      T0*|t0*) ;;   # T0 baseline lane: the acceptance oracle is the check, no Verifier
      *) if [ "$hv" != 1 ]; then
           echo "orchestrate: refusing 'done' for $tk — no Verifier verdict on the board (tier=${tier:-unknown}). A T1/T2 lane must pass a Verifier first: dispatch the verifier, record its verdict, then mark done. (T0 baseline lanes are exempt — set tier=T0 at intake.)" >&2
           exit 3
         fi ;;
    esac
    printf '{"ts":"%s","ticket":"%s","event":"done"}\n' "$(date -u +%FT%TZ)" "$tk" >> "$LEDGER"
    # Lane close retires this ticket's writer records (ADR-0039), so a forgotten
    # `writer-ctx clear actuator` cannot leave an already-acked prod context armed
    # for the next dispatch. Other tickets' records are untouched.
    for awf in "$ROOT"/active-writer.*.json; do
      [ -f "$awf" ] && [ "$(sed -n 's/^ticket=//p' "$awf")" = "$tk" ] && rm -f "$awf"
    done; true ;;

  writer-ctx)  # per-dispatch enforcement context (ADR-0006): the router writes this
               # BEFORE dispatching a writer; the hooks read it (CC passes no router
               # env to subagent hooks). Line format -> no jq needed. ONE record PER
               # PERSONA (ADR-0039): active-writer.<persona>.json, so a builder's
               # set/clear can never blank or retarget the actuator's gate context.
               # Each hook reads only its own persona's file. The pre-0.8.29 single
               # slot (active-writer.json) is never read; reground HALTs on it.
    sub="${1:-}"; shift || true
    # The persona names the file, so normalize it the way the hooks do (strip a
    # plugin namespace such as orchestrate:actuator) and accept only the two
    # writer personas; anything else is a usage error, never a stray file.
    wpers(){ local p="${1##*:}"; case "$p" in implementer|actuator) printf '%s' "$p" ;;
             *) echo "writer-ctx: persona must be implementer or actuator (got '${1:-}')" >&2; return 64 ;; esac; }
    case "$sub" in
      set)   # set <ticket> <persona> <assigned_branch> [prod_target...]
        wt="${1:?ticket}"; wp="$(wpers "${2:-}")" || exit 64; wb="${3:-}"; pt="${*:4}"; mkdir -p "$ROOT"
        printf 'ticket=%s\npersona=%s\nassigned_branch=%s\nprod_targets=%s\nts=%s\n' \
          "$wt" "$wp" "$wb" "$pt" "$(date -u +%FT%TZ)" > "$ROOT/active-writer.$wp.json" ;;
      get)   # get <persona> <key>  (empty output when that persona has no record)
        k="${2:-}"; [ -n "${1:-}" ] && [ -n "$k" ] || { echo "usage: ledger.sh writer-ctx get <persona> <key>" >&2; exit 64; }
        wp="$(wpers "$1")" || exit 64
        f="$ROOT/active-writer.$wp.json"; [ -f "$f" ] || exit 0; sed -n "s/^$k=//p" "$f" ;;
      clear) # clear [persona]  (no persona: every persona record plus the legacy slot)
        if [ -n "${1:-}" ]; then wp="$(wpers "$1")" || exit 64; rm -f "$ROOT/active-writer.$wp.json"
        else rm -f "$ROOT"/active-writer.*.json "$ROOT/active-writer.json"; fi ;;
      *) echo "usage: ledger.sh writer-ctx set <ticket> <persona> <branch> [prod...] | get <persona> <key> | clear [persona]" >&2; exit 64 ;;
    esac ;;

  *) echo "usage: ledger.sh {append '<json>'|retries <ticket>|reground|metrics [ticket]|feedback <note>|conformance <event[:detail]>...|clarify <skill> [ticket]|done <ticket>|lease-{key,acquire,release,check}|ack|decision <ticket> <fork_id> [adr]|writer-ctx set|get|clear}" >&2; exit 64 ;;
esac
