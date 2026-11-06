R="$HERE/../skills/orchestrate/runtime/ledger.sh"
A="$HERE/../skills/orchestrate/runtime/adr.sh"

# --- decision-event writer (capture half of judgment memory, SKILL.md "Judgment memory") ---
d="$(mktemp_repo)"; cd "$d"
bash "$R" decision T1 fork-7 0008-foo
grep -q '"ticket":"T1".*"event":"decision".*"fork_id":"fork-7".*"adr":"0008-foo"' .agents/runs/orchestrate/board.jsonl \
  && pass || fail "decision event written with adr"
# resolved-but-not-promoted: adr omitted -> empty adr field, event still recorded
bash "$R" decision T2 fork-9
grep -q '"ticket":"T2".*"event":"decision".*"fork_id":"fork-9"' .agents/runs/orchestrate/board.jsonl \
  && pass || fail "decision event written without adr"
grep '"ticket":"T2"' .agents/runs/orchestrate/board.jsonl | grep -q '"note"' \
  && fail "decision without a note carries no note field" || pass
# prod confirmation (SKILL.md "Production changes"): the operator's answer lands as note,
# escaped, so a decline never reads like an approval
bash "$R" decision T3 prod-ack:tfstate:prod/net "" 'declined: not today, "freeze" week'
l="$(grep '"ticket":"T3"' .agents/runs/orchestrate/board.jsonl)"
case "$l" in *'"fork_id":"prod-ack:tfstate:prod/net"'*'"note":"declined: not today, \"freeze\" week"'*) pass;; *) fail "decision note journaled and escaped: $l";; esac
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$l" | jq -e '.note=="declined: not today, \"freeze\" week"' >/dev/null 2>&1 && pass || fail "decision line with a note is valid JSON"
fi
cd /; rm -rf "$d"

# --- adr.sh reindex: INDEX derived from files, so ANY tool's ADRs are recalled ---
d="$(mktemp_repo)"; cd "$d"; mkdir -p docs/adr
printf '# First decision\n\n_Status: active_\n' > docs/adr/0001-first.md
printf '# Second decision\n\n_Status: superseded by 0003_\n' > docs/adr/0002-second.md
# an ADR an EXTERNAL tool wrote: conformant name, no _Status_ line
printf '# Third by another tool\n\ncontext only, no status line\n' > docs/adr/0003-third.md
# an ACTIVE ADR whose BODY mentions "supersede" in prose must not trip set -e or be mis-statused
printf '# Fourth decision\n\nthis references the supersede flow in prose but is itself active\n' > docs/adr/0004-fourth.md
bash "$A" reindex; rc=$?
assert_eq "$rc" "0" "reindex survives body-prose 'supersede' (no set -e abort / truncation)"
assert_file docs/adr/INDEX.md
grep -q '0004-fourth.md' docs/adr/INDEX.md && pass || fail "reindex did not truncate (0004 present)"
awk '/0004-fourth/' docs/adr/INDEX.md | grep -qi 'active' && pass || fail "body-prose 'supersede' ADR stays active"
grep -q '0001-first.md' docs/adr/INDEX.md && pass || fail "reindex includes 0001"
grep -q 'First decision'  docs/adr/INDEX.md && pass || fail "reindex pulls the title from the file"
grep -q '0003-third.md'   docs/adr/INDEX.md && pass || fail "reindex picks up externally-authored ADR"
awk '/0003-third/' docs/adr/INDEX.md | grep -qi 'active' && pass || fail "external ADR (no status line) defaults active"
printf '# Fifth decision\n\n_Status: active_\n\n## Amended by ADR-0006\n\nnarrowed.\n' > docs/adr/0005-fifth.md
bash "$A" reindex
awk '/0005-fifth/' docs/adr/INDEX.md | grep -q '| active, amended by 0006 |' && pass || fail "an amended active ADR says so in the index"
awk '/0001-first/' docs/adr/INDEX.md | grep -q '| active |' && pass || fail "an unamended active ADR stays plain active"
awk '/0002-second/' docs/adr/INDEX.md | grep -q 'superseded by 0003' && pass || fail "reindex preserves superseded status"
# supersede marks the FILE (so reindex stays consistent), then INDEX reflects it
bash "$A" supersede 0001 0009
grep -qi 'superseded by 0009' docs/adr/0001-first.md && pass || fail "supersede marks the ADR file"
bash "$A" reindex
awk '/0001-first/' docs/adr/INDEX.md | grep -q 'superseded by 0009' && pass || fail "reindex reflects file supersede"
cd /; rm -rf "$d"
