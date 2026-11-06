# PreToolUse(Bash) gate: sweeping stage/commit forms are denied (exit 2, reason on
# stderr); explicit-path staging and everything else passes silently (exit 0).
G="$HERE/../hooks/guard-git-staging.sh"
deny(){ run_hook "$G" "$(bash_payload "$1")"; assert_eq "$RC" 2 "deny: $1"; assert_contains "$ERR" "guards:" "reason present: $1"; }
allow(){ run_hook "$G" "$(bash_payload "$1")"; assert_eq "$RC" 0 "allow: $1"; assert_eq "$ERR" "" "silent: $1"; }

# --- denied: stage-everything forms
deny 'git add -A'
deny 'git add --all'
deny 'git add .'
deny 'git add ./'
deny 'git add -- .'
deny 'git add *'
deny 'git add :/'
deny 'git add -u'
deny 'git add -u .'
deny 'git add -u -- .'
deny 'git add -u -- ./'
deny 'git add -u -- :/'
deny 'git add -u -- "*"'
deny 'git add -u --'
deny 'git add -u -- $FILES'
deny 'git add -u -- 2>&1'
deny 'git add -u -- # note'
deny 'git add -u -- &>/dev/null'
deny 'git add -u -- "$PWD"'
deny 'git add -u src/a.py'
deny 'git add --update -- ..'
deny 'git add -u -- src/a.py .'
deny 'git add --update'
deny 'git add -Av'
deny 'git add -vA'
deny 'git add -A -- src/'
deny 'git add src/a.py .'
# --- denied: commit -a forms
deny 'git commit -a'
deny 'git commit -a -m "msg"'
deny 'git commit -am "msg"'
deny 'git commit --all -m "msg"'
deny 'git commit -sam "msg"'
# --- denied: git global options and chaining do not hide it
deny 'git -C /tmp/x add .'
deny 'git -c user.name=x add -A'
deny 'git --git-dir=/tmp/x/.git --work-tree=/tmp/x add -A'
deny 'cd repo && git add . && git commit -m x'
deny 'git status; git add -A; git commit -m x'
deny 'git fetch | tee log && git commit -am x'
deny $'git status\ngit add .'
deny '/usr/bin/git add .'

# --- allowed: explicit paths and unrelated commands
allow 'git add README.md'
allow 'git add src/a.py src/b.py'
allow 'git add -- src/a.py'
allow 'git add -u -- src/a.py'
allow 'git add --update -- src/a.py src/b.py'
allow 'git add -u -- .claude/mods/context-bar'
allow 'git -C /x add -u -- "src"'
allow 'git add -u -- "src/my file.txt"'
allow 'git add -p src/a.py'
allow 'git add -N newfile.py'
allow 'git add ./src/a.py'
allow 'git add .github/workflows/ci.yml'
allow 'git add .gitignore'
allow 'git commit -m "msg"'
allow 'git commit --amend --no-edit'
allow 'git commit --author="a <a@b>" -m x'
allow 'git commit -S -m x'
allow 'git commit -m "git add . is bad"'
allow 'git status'
allow 'git diff --stat .'
allow 'git log -- .'
allow 'git checkout -- .'
allow 'git stash push -u'
allow 'dotfiles add -u'
allow 'ls -a .'
allow 'echo "git add -A"'
allow 'rg -n "commit -a" docs/'
allow ''

# --- denied: quoted sweeping pathspecs, two-token global options, subshell form
deny 'git add "."'
deny "git add '*'"
deny "git add ':/'"
deny 'git add ..'
deny 'git add ../'
deny 'git --git-dir /tmp/x/.git add .'
deny '(git add . && git commit -m x)'
deny 'git add -A -- .'
deny 'git commit -qa'

# --- allowed: quoted text is never a flag (the review-found false positives)
allow 'git commit -m "fix -a flag"'
allow 'git commit -m "docs: note -a is denied"'
allow 'git commit -m "feat(guards): deny git add -A and git commit -a" plugins/guards'
allow 'git commit --author="Some -a Person <a@b>" -m x'
allow 'git commit -m "-am"'
allow $'git commit -m "$(cat <<\'EOF\'\nfeat: staging gate\n\n- deny git add -A and git commit -a\nEOF\n)"'
allow $'git add README.md && git commit -m "$(cat <<EOF\nrun: git add -A is blocked\nEOF\n)"'
allow 'echo "run: git add -A" && git add file.txt'
allow 'git add "src/my file.txt"'
allow 'git add --chmod=+x file'
allow 'git commit --fixup=abc'
allow 'git rm -r --cached .'

# separators inside quoted strings do not split the command
deny 'git commit -m "it works; ship" -a'
deny 'git add . ; echo "x && y"'
allow 'git commit -m "a && b" -- f'
allow 'git add src/x && git commit -m "fix; done" -- src/x'

# heredoc skipping must not swallow a real sweep AFTER the terminator
deny $'cat <<EOF\nhello\nEOF\ngit add -A'

# --- fail-open: empty or non-Bash payload
run_hook "$G" '{"tool_name":"Bash","tool_input":{}}'; assert_eq "$RC" 0 "no command field -> allow"
run_hook "$G" 'not json'; assert_eq "$RC" 0 "unparseable payload -> allow"
