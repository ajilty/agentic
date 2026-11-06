#!/usr/bin/env bash
# adr.sh — judgment-memory helper: sequential ADR numbering + INDEX maintenance.
# Operates on ./docs/adr/ (tracked; ADR-0003/0005). Pure coreutils/sed/awk, no deps.
# The rationale prose is authored by the Planner/operator; this only mechanizes
# numbering, the INDEX row, and supersede status so capture can't race or drift.
#
#   adr.sh next                      # print the next zero-padded 4-digit number
#   adr.sh add <slug> <title>        # create docs/adr/NNNN-<slug>.md + active INDEX row; print the path
#   adr.sh supersede <NNNN> <byNNNN> # flip the NNNN row's status to "superseded by <byNNNN>"
set -euo pipefail
ADRDIR="docs/adr"; INDEX="$ADRDIR/INDEX.md"

ensure_index() {
  [ -f "$INDEX" ] && return 0
  mkdir -p "$ADRDIR"
  { echo "# Decision Index"; echo
    echo "One line per decision; the Planner reads this at intake and does not"
    echo "re-litigate an active decision. A goal contradicting an active record"
    echo "raises a DECISION_FORK citing it (supersede flow)."; echo
    echo "| ADR | Decision | Status |"
    echo "|-----|----------|--------|"
  } > "$INDEX"
}

next_num() {
  local last
  last="$(ls "$ADRDIR" 2>/dev/null | grep -oE '^[0-9]{4}' | sort -n | tail -1 || true)"
  printf '%04d\n' "$(( 10#${last:-0} + 1 ))"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  next) next_num ;;

  add)
    slug="${1:?slug}"; title="${2:?title}"
    mkdir -p "$ADRDIR"; ensure_index
    num="$(next_num)"; f="$ADRDIR/$num-$slug.md"
    { printf '# %s\n\n' "$title"
      printf '<!-- captured from a DECISION_FORK resolution; fill in context + why -->\n\n'
      printf '_Status: active_\n'
    } > "$f"
    printf '| [%s](%s-%s.md) | %s | active |\n' "$num" "$num" "$slug" "$title" >> "$INDEX"
    printf '%s\n' "$f" ;;

  supersede)
    num="${1:?num}"; by="${2:?by}"
    # Mark the ADR file (the source of truth, so reindex stays consistent)...
    for f in "$ADRDIR/$num"-*.md; do
      [ -e "$f" ] || continue
      if grep -qi '^_status:' "$f"; then
        sed -E "s/^_[Ss]tatus:.*/_Status: superseded by ${by}_/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      else
        printf '\n_Status: superseded by %s_\n' "$by" >> "$f"
      fi
    done
    # ...and flip the index row in place if present (reindex would reproduce this).
    [ -f "$INDEX" ] && { sed -E "/\| \[$num\]/ s/\| active \|/| superseded by $by |/" "$INDEX" > "$INDEX.tmp" && mv "$INDEX.tmp" "$INDEX"; }
    : ;;

  reindex)   # rebuild INDEX.md from docs/adr/*.md (files = source of truth), so ADRs
             # written by ANY tool (e.g. grill-with-docs) are recalled at intake.
    mkdir -p "$ADRDIR"
    { echo "# Decision Index"; echo
      echo "Rebuilt from docs/adr/*.md by \`adr.sh reindex\`. The Planner reads this at"
      echo "intake and does not re-litigate an active decision; a goal contradicting one"
      echo "raises a DECISION_FORK citing it (supersede flow)."; echo
      echo "| ADR | Decision | Status |"
      echo "|-----|----------|--------|"
      for f in "$ADRDIR"/[0-9]*.md; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"; num="${base%%-*}"
        title="$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^#[[:space:]]*//' || true)"; [ -z "$title" ] && title="$base"
        # Status comes ONLY from a status line (`_Status:` or frontmatter `status:`),
        # never arbitrary body prose. Guard every substitution so set -e/pipefail
        # cannot abort the rebuild mid-loop and silently truncate the index.
        sline="$(grep -m1 -iE '^_?status:' "$f" 2>/dev/null || true)"
        case "$sline" in
          *[Ss]upersed*)
            status="$(printf '%s' "$sline" | grep -oiE 'superseded by [0-9A-Za-z-]+' || true)"
            [ -z "$status" ] && status="superseded" ;;
          *) status="active"
             # An active ADR amended by a later one says so, so a planner reading the
             # index alone does not take the original title as the whole decision.
             am="$(grep -oE '^## Amended by ADR-[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+$' | paste -sd, - || true)"
             [ -n "$am" ] && status="active, amended by ${am//,/, }" ;;
        esac
        printf '| [%s](%s) | %s | %s |\n' "$num" "$base" "$title" "$status"
      done
    } > "$INDEX" ;;

  *) echo "usage: adr.sh {next|add <slug> <title>|supersede <NNNN> <byNNNN>|reindex}" >&2; exit 64 ;;
esac
