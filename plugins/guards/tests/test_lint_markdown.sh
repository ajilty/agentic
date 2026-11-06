# PostToolUse(Write|Edit) markdown lint: findings for the one written .md file go
# back to the model (exit 2, stderr); clean files and non-markdown pass silently.
L="$HERE/../hooks/lint-markdown.sh"
if ! command -v rumdl >/dev/null 2>&1; then
  skip "rumdl absent: lint-markdown behaviour untested (only fail-open checked)"
  run_hook "$L" "$(file_payload "$HERE/../README.md")"; assert_eq "$RC" 0 "rumdl absent -> silent pass"
else
  R="$(mktemp_repo)"
  printf '# Good\n\nFine.\n' > "$R/good.md"
  printf '# Title\n\n#Not a heading\n\n\n\ntext\n' > "$R/bad.md"
  printf '{"a":' > "$R/notmd.json"

  run_hook "$L" "$(file_payload "$R/good.md")"; assert_eq "$RC" 0 "clean md -> 0"; assert_eq "$ERR" "" "clean md -> silent"
  run_hook "$L" "$(file_payload "$R/bad.md")"; assert_eq "$RC" 2 "bad md -> 2"
  assert_contains "$ERR" "MD018" "finding rule id surfaced"
  assert_contains "$ERR" "bad.md" "finding names the file"
  assert_contains "$ERR" "guards:" "guards prefix"
  run_hook "$L" "$(file_payload "$R/notmd.json")"; assert_eq "$RC" 0 "non-md -> skipped"
  run_hook "$L" "$(file_payload "$R/missing.md")"; assert_eq "$RC" 0 "vanished file -> 0"
  run_hook "$L" '{}'; assert_eq "$RC" 0 "no file_path -> 0"

  # Never auto-fix: file content must be byte-identical after the hook runs.
  before=$(cat "$R/bad.md"); run_hook "$L" "$(file_payload "$R/bad.md")"; assert_eq "$(cat "$R/bad.md")" "$before" "check-only, file untouched"

  # No cache litter in the repo or the file's directory.
  [ -z "$(find "$R" -name '.rumdl_cache' -print -quit)" ] && pass || fail "rumdl cache dir littered into repo"

  # Config discovery starts at the FILE, not the hook's cwd: a repo-level
  # .markdownlint.yaml disabling MD013 must win even when cwd is elsewhere.
  R2="$(mktemp_repo)"; printf 'MD013: false\n' > "$R2/.markdownlint.yaml"
  # MD013 ignores unbreakable tokens (URLs), so the long line needs spaces; no
  # trailing space or MD009 fires instead and masks what is being tested.
  printf '# T\n\n%sword\n' "$(printf 'word %.0s' $(seq 1 39))" > "$R2/long.md"
  pushd / >/dev/null
  run_hook "$L" "$(file_payload "$R2/long.md")"; assert_eq "$RC" 0 "repo config honoured from foreign cwd"
  rm "$R2/.markdownlint.yaml"
  run_hook "$L" "$(file_payload "$R2/long.md")"; assert_eq "$RC" 2 "without repo config MD013 fires"; assert_contains "$ERR" "MD013" "MD013 is the finding"
  popd >/dev/null

  # Global XDG config is honoured when the repo has none.
  mkdir -p "$XDG_CONFIG_HOME/rumdl"; printf '[global]\ndisable = ["MD013"]\n' > "$XDG_CONFIG_HOME/rumdl/rumdl.toml"
  run_hook "$L" "$(file_payload "$R2/long.md")"; assert_eq "$RC" 0 "global ~/.config/rumdl/rumdl.toml honoured"
  # A broken global config is surfaced, not swallowed.
  printf 'not toml [[[\n' > "$XDG_CONFIG_HOME/rumdl/rumdl.toml"
  run_hook "$L" "$(file_payload "$R/good.md")"; assert_eq "$RC" 2 "broken config -> surfaced"; assert_contains "$ERR" "TOML" "broken config error text surfaced"
  # No ANSI escapes reach the model.
  case "$ERR" in *"$(printf '\033')"*) fail "ANSI escapes in hook output" ;; *) pass ;; esac
  rm -rf "$XDG_CONFIG_HOME/rumdl"

  # Long finding lists are truncated so a single write cannot flood context.
  { echo '# T'; echo; for i in $(seq 1 40); do echo "#h$i"; done; } > "$R/many.md"
  run_hook "$L" "$(file_payload "$R/many.md")"; assert_eq "$RC" 2 "many findings -> 2"
  assert_contains "$ERR" "more" "truncation notice present"
  n=$(printf '%s\n' "$ERR" | grep -c '\[MD'); [ "$n" -le 20 ] && pass || fail "findings capped at 20 (got $n)"

  # Scope: only ship-bound files are linted. Throwaway and memory locations are
  # skipped silently even when the file has findings.
  for sub in tmp/x scratchpad/x .cache/x .claude/projects/p/memory; do
    mkdir -p "$R/$sub"; cp "$R/bad.md" "$R/$sub/bad.md"
    run_hook "$L" "$(file_payload "$R/$sub/bad.md")"
    assert_eq "$RC" 0 "skipped location $sub -> 0"; assert_eq "$ERR" "" "skipped location $sub -> silent"
  done
  # Positive control: a repo-shaped path with a known finding still reports.
  mkdir -p "$R/docs"; cp "$R/bad.md" "$R/docs/bad.md"
  run_hook "$L" "$(file_payload "$R/docs/bad.md")"; assert_eq "$RC" 2 "repo path still linted"; assert_contains "$ERR" "MD018" "repo path finding surfaced"
fi
