# Run state that only 0.8.x wrote (active-writer.json, leases/) is archived by reground,
# announced once, and never read as a writer limit: a second reground is silent about it.
R="$HERE/../skills/orchestrate/runtime/ledger.sh"
d="$(mktemp_repo)"; cd "$d"; git commit -qm init --allow-empty
ROOTD=".agents/runs/orchestrate"
printf '{"ticket":"T1","persona":"implementer"}\n' > "$ROOTD/active-writer.json"
mkdir -p "$ROOTD/leases"; printf 'T2\n' > "$ROOTD/leases/tfstate:prod%2Fdb"
mkdir -p "$ROOTD/tickets/T1"; printf 'x\n' > "$ROOTD/tickets/T1/lease"; printf 'y\n' > "$ROOTD/tickets/T1/ack-prod"
printf 'keep\n' > "$ROOTD/tickets/T1/work-item.md"
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}'
out="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "reground exits 0 with legacy state present"
case "$out" in *"LEGACY STATE: moved active-writer.json leases tickets/T1/lease tickets/T1/ack-prod to .agents/runs/orchestrate/legacy/"*) pass;; *) fail "reground announces the archived legacy files ($out)";; esac
case "$out" in *"no current version reads them"*) pass;; *) fail "the announcement says the files carry no writer limit ($out)";; esac
assert_no_file "$ROOTD/active-writer.json"
[ ! -e "$ROOTD/leases" ] && pass || fail "leases/ left in place"
arch="$(ls -d "$ROOTD"/legacy/*/ 2>/dev/null | head -1)"
assert_file "${arch}active-writer.json"
assert_file "${arch}leases/tfstate:prod%2Fdb"
assert_file "${arch}tickets/T1/lease"
assert_file "${arch}tickets/T1/ack-prod"
assert_file "$ROOTD/tickets/T1/work-item.md"
assert_no_file "$ROOTD/tickets/T1/lease"
grep -q '"ticket":"T1"' "${arch}active-writer.json" && pass || fail "archived file content preserved"
out2="$(bash "$R" reground 2>&1)"; rc=$?
assert_eq "$rc" "0" "second reground exits 0"
case "$out2" in *"LEGACY STATE"*) fail "second reground must not announce again ($out2)";; *) pass;; esac
case "$out2" in *"REGROUND: clean"*) pass;; *) fail "reground still reports after the sweep ($out2)";; esac
# a board with no legacy files prints nothing about them
d2="$(mktemp_repo)"; cd "$d2"; git commit -qm init --allow-empty
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}'
out3="$(bash "$R" reground 2>&1)"
case "$out3" in *"LEGACY"*) fail "no legacy line without legacy files ($out3)";; *) pass;; esac
[ ! -e ".agents/runs/orchestrate/legacy" ] && pass || fail "no legacy folder created without legacy files"
# an unwritable run dir never fails reground: no archive, no LEGACY line, report intact
d3="$(mktemp_repo)"; cd "$d3"; git commit -qm init --allow-empty
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}'
printf '{}\n' > ".agents/runs/orchestrate/active-writer.json"; chmod a-w .agents/runs/orchestrate
out4="$(bash "$R" reground 2>&1)"; rc=$?
chmod u+w .agents/runs/orchestrate
assert_eq "$rc" "0" "reground exits 0 when the run dir is unwritable ($out4)"
case "$out4" in *"LEGACY STATE"*) fail "no announcement when nothing could be archived ($out4)";; *) pass;; esac
case "$out4" in *"REGROUND: clean"*) pass;; *) fail "report intact despite the failed archive ($out4)";; esac
assert_file ".agents/runs/orchestrate/active-writer.json"
# two regrounds racing on the same files both exit 0; at most one announces
d4="$(mktemp_repo)"; cd "$d4"; git commit -qm init --allow-empty
bash "$R" append '{"ticket":"T1","event":"intake","tier":"T1"}'
printf '{}\n' > ".agents/runs/orchestrate/active-writer.json"
bash "$R" reground > r1.out 2>&1 & p1=$!
bash "$R" reground > r2.out 2>&1 & p2=$!
wait $p1; rc1=$?; wait $p2; rc2=$?
assert_eq "$rc1$rc2" "00" "both racing regrounds exit 0 ($(cat r1.out r2.out))"
n="$(cat r1.out r2.out | grep -c 'LEGACY STATE' || true)"
[ "$n" -le 1 ] && pass || fail "at most one racer announces (got $n)"
cd /; rm -rf "$d" "$d2" "$d3" "$d4"
