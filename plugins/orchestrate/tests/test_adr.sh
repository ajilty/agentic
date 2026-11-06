A="$HERE/../skills/orchestrate/runtime/adr.sh"
d="$(mktemp_repo)"; cd "$d"
mkdir -p docs/adr
# next on an empty adr dir -> 0001
assert_eq "$(bash "$A" next)" "0001" "next on empty adr dir"
# decimal (not octal) numbering: 0001 + 0007 present -> next 0008
: > docs/adr/0001-foo.md; : > docs/adr/0007-bar.md
assert_eq "$(bash "$A" next)" "0008" "next picks highest+1, decimal not octal"
# add creates the file, returns its path, and seeds INDEX.md if absent
p="$(bash "$A" add baz 'Use Baz over Qux')"
assert_file "$p"
case "$p" in *docs/adr/0008-baz.md) pass;; *) fail "add returns the new adr path (got $p)";; esac
assert_file "docs/adr/INDEX.md"
grep -q '0008-baz.md' docs/adr/INDEX.md && pass || fail "add appends an INDEX row for the new ADR"
grep -qi 'active' docs/adr/INDEX.md && pass || fail "new ADR row is marked active"
# the title appears in the created ADR body
grep -q 'Use Baz over Qux' "$p" && pass || fail "title written into the ADR file"
# supersede flips the active row's status
bash "$A" supersede 0008 0009
grep -q 'superseded by 0009' docs/adr/INDEX.md && pass || fail "supersede flips status in INDEX"
[ -z "$(find . -name '*-E' -not -path './.git/*')" ] && pass || fail "supersede leaves no stray *-E sed backup file"
cd /; rm -rf "$d"
