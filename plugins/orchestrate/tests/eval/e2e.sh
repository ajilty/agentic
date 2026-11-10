#!/usr/bin/env bash
# Tier 3c, end to end: run the REAL router loop headless on an effectiveness
# fixture, per plugin variant, and score the delivered change against the
# fixture's held-out oracle. Where run.sh drives personas single-pass and
# replay.sh stops at the first dispatch, this one lets the whole loop run, so it
# sees what an intake change costs in time, money and correctness.
#
#   bash tests/eval/e2e.sh <out-dir> <label>=<plugin-dir> [<label>=<plugin-dir> ...]
#   bash tests/eval/e2e.sh <out-dir>      # no arms: reprint the scorecard, run nothing
#
# Env: E2E_K (runs per arm, default 2), E2E_JOBS (parallel sessions, default 2),
# E2E_FIXTURE (default discount-coupling), E2E_MODEL (opus), E2E_EFFORT (low),
# E2E_BUDGET_USD (per session, 6), E2E_TIMEOUT (seconds, 1500).
#
# Isolation: throwaway HOME (only the OAuth credential, the operator's CLAUDE.md
# and clarification skills copied in), throwaway cwd, `env -i` with only HOME,
# PATH, TERM, LANG, TMPDIR and ANTHROPIC_DEFAULT_OPUS_MODEL. Each plugin is staged
# into the sandbox WITHOUT its tests/ (the held-out oracle lives there) and with
# a `skills/` sibling so its relative craft-skill links resolve the same way for
# every arm. The held-out oracle is never copied into the sandbox and
# HELDOUT_ROOT is not set: the session cannot see it.
#
# There is no command guard here, unlike replay.sh: the loop must really run.
# The isolation above is the whole control, so point this only at a toy fixture,
# never at a snapshot of a real project.
#
# The seed is a git repo with a local bare `origin` (the loop needs worktrees and
# a base). The router's default landing is a hand-over, so the change may sit on
# a lane branch: the oracle is run on the main checkout first, then on every
# worktree and branch; `where` says which one passed.
#
# Reporting only; never a CI gate. Self-skips without claude/auth/python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INT_HERE="$HERE/../integration"; export INT_HERE
. "$INT_HERE/lib.sh"

OUT="${1:?usage: e2e.sh <out-dir> <label>=<plugin-dir> ...}"; shift
have_claude    || { echo "(skip e2e: claude not on PATH)"; exit 0; }
have_live_auth || { echo "(skip e2e: no live auth)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "(skip e2e: python3 absent)"; exit 0; }
int_space_ok   || { echo "(skip e2e: low tmp space)"; exit 0; }

K="${E2E_K:-2}"; JOBS="${E2E_JOBS:-2}"; FXNAME="${E2E_FIXTURE:-discount-coupling}"
MODEL="${E2E_MODEL:-opus}"; EFFORT="${E2E_EFFORT:-low}"
BUDGET="${E2E_BUDGET_USD:-6}"; TMO="${E2E_TIMEOUT:-1500}"
FX="$HERE/fixtures/$FXNAME"; ORACLE="$FX/heldout/test_oracle.py"
[ -d "$FX/seed" ] && [ -f "$ORACLE" ] && [ -f "$FX/goal.md" ] || { echo "e2e: bad fixture $FXNAME" >&2; exit 2; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

declare -A ARM=()
for a in "$@"; do
  l="${a%%=*}"; d="${a#*=}"
  [ -n "$l" ] && [ "$l" != "$a" ] && [ -d "$d/skills/orchestrate" ] || { echo "e2e: bad arm '$a'" >&2; exit 2; }
  ARM[$l]="$(cd "$d" && pwd)"
done

# The caller may be an agent session whose PATH carries an INSTALLED copy of this
# plugin's helpers; the session must run the helpers of the plugin under test.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.claude/plugins/' -e '/plugins/[^/]*/bin$' | paste -sd: -)"

stage_plugin(){ # <src> <dest-root> ; echoes the staged plugin dir
  local src="$1" root="$2" dst
  dst="$root/plugins/$(basename "$src")"; mkdir -p "$root/plugins"
  cp -a "$src" "$dst"; rm -rf "$dst/tests"
  ln -s "$REPO_ROOT/skills" "$root/skills"      # plugins/<p>/skills/<x> -> ../../../skills/coding/<x>
  printf '%s\n' "$dst"
}

seed_repo(){ # <dir>  (seed copied exactly as run.sh does, then put under git with an origin)
  local d="$1" bare="$1.origin.git"
  mkdir -p "$d"; cp "$FX/seed/"*.py "$d/"
  ( cd "$d" && git init -q -b main && git config user.email t@t && git config user.name t \
      && printf '.agents/\n__pycache__/\n' >> .git/info/exclude && git add -A && git commit -qm seed \
      && git init -q --bare "$bare" && git remote add origin "$bare" && git push -q origin main \
      && git remote set-head origin main ) >/dev/null 2>&1
}

score_repo(){ # <repo> <o> ; writes score.env: visible heldout where
  local repo="$1" o="$2" v=0 h=0 where=none p ref t
  ( cd "$repo" && python3 test_cart.py ) >/dev/null 2>&1 && v=1
  if python3 "$ORACLE" "$repo" > "$o/oracle-main.txt" 2>&1; then h=1; where=main; fi
  if [ "$where" = none ]; then
    while read -r p; do
      [ "$p" = "$repo" ] && continue
      python3 "$ORACLE" "$p" >/dev/null 2>&1 && { where="worktree:${p##*/}"; break; }
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  fi
  if [ "$where" = none ]; then
    while read -r ref; do
      t="$(mktemp -d "$_INT_RUN_DIR/ref.XXXXXX")"
      git -C "$repo" archive "$ref" 2>/dev/null | tar -x -C "$t" 2>/dev/null
      python3 "$ORACLE" "$t" >/dev/null 2>&1 && { where="branch:${ref#refs/*/}"; break; }
    done < <(git -C "$repo" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null)
  fi
  printf 'visible=%s heldout=%s where=%s\n' "$v" "$h" "$where" > "$o/score.env"
}

run_one(){ # <label> <k>
  local l="$1" k="$2" o="$OUT/$1.$2" root home repo pdir
  rm -rf "$o"; mkdir -p "$o"
  root="$(mk_tmp)"; home="$(mk_authed_home)"; repo="$root/repo"
  pdir="$(stage_plugin "${ARM[$l]}" "$root")"
  seed_repo "$repo"
  [ -f "$HOME/.claude/CLAUDE.md" ] && cp -L "$HOME/.claude/CLAUDE.md" "$home/.claude/CLAUDE.md" 2>/dev/null
  mkdir -p "$home/.claude/skills"
  for s in grill-with-docs grill-me brainstorming; do
    [ -d "$HOME/.claude/skills/$s" ] && cp -rL "$HOME/.claude/skills/$s" "$home/.claude/skills/" 2>/dev/null
  done
  printf '%s\n' "${ARM[$l]}" > "$o/plugin-src"
  local t0; t0="$(date +%s)"
  { printf '/orchestrate:init '; cat "$FX/goal.md"; } | ( cd "$repo" && /usr/bin/env -i \
      HOME="$home" PATH="$CLEAN_PATH" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
      ${ANTHROPIC_DEFAULT_OPUS_MODEL:+ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL"} \
      timeout "$TMO" claude -p --model "$MODEL" --effort "$EFFORT" --plugin-dir "$pdir" \
        --output-format json --max-budget-usd "$BUDGET" \
        --allowedTools "Read,Grep,Glob,Write,Edit,Bash,Agent,Task,Skill" ) > "$o/result.json" 2> "$o/stderr.txt"
  echo "rc=$? wall=$(( $(date +%s) - t0 ))" > "$o/exit.env"
  cp "$repo/.agents/runs/orchestrate/board.jsonl" "$o/board.jsonl" 2>/dev/null
  cp -r "$repo/.agents/runs/orchestrate/tickets" "$o/tickets" 2>/dev/null
  cp -r "$repo/.agents/runs/orchestrate/verdicts" "$o/verdicts" 2>/dev/null
  mkdir -p "$o/transcripts"; cp -r "$home/.claude/projects/." "$o/transcripts/" 2>/dev/null
  ( cd "$repo" && git status --porcelain=v1 --untracked-files=all; echo '--- worktrees'; git worktree list
    echo '--- refs'; git for-each-ref --format='%(refname) %(objectname:short) %(subject)'
    echo '--- diff vs seed'; git diff "$(git rev-list --max-parents=0 HEAD | tail -1)" -- '*.py' ) > "$o/git-state.txt" 2>&1
  score_repo "$repo" "$o"
  echo "  done: $l.$k ($(cat "$o/score.env"))"
}

row(){ python3 - "$1" <<'PY'
import glob, json, os, re, sys
o = sys.argv[1].rstrip("/")
def kv(p):
    try: return dict(x.split("=", 1) for x in open(p).read().split())
    except Exception: return {}
def jl(p):
    out = []
    for f in glob.glob(p):
        for l in open(f, errors="replace"):
            try: out.append(json.loads(l))
            except Exception: pass
    return out
sc, ex = kv(o + "/score.env"), kv(o + "/exit.env")
try: res = json.load(open(o + "/result.json"))
except Exception: res = {}
rows = jl(o + "/board.jsonl")
ev = [r.get("event") for r in rows]
disp = {}
for r in rows:
    if r.get("event") == "dispatched":
        p = str(r.get("persona", "?")); disp[p] = disp.get(p, 0) + 1
dstr = ",".join("%s%d" % (p[:4], n) for p, n in sorted(disp.items())) or "-"
# What the router actually did, from its own transcript (main session files only).
calls, inline, seen = {}, 0, set()
for m in jl(o + "/transcripts/*/*.jsonl"):
    if m.get("isSidechain"): continue
    c = (m.get("message") or {}).get("content")
    if not isinstance(c, list): continue
    for b in c:
        if not isinstance(b, dict) or b.get("type") != "tool_use" or b.get("id") in seen: continue
        seen.add(b.get("id"))   # the transcript can log one call on two lines
        n, i = b.get("name"), b.get("input") or {}
        if n in ("Agent", "Task"):
            s = str(i.get("subagent_type", "?")).split(":")[-1]; calls[s] = calls.get(s, 0) + 1
        elif n in ("Edit", "Write") and str(i.get("file_path", "")).endswith(".py"):
            inline += 1
cstr = ",".join("%s%d" % (p[:4], n) for p, n in sorted(calls.items())) or "-"
read = "y" if glob.glob(o + "/tickets/*/reading.md") else "-"
asm, verdict = "-", "-"
for f in glob.glob(o + "/tickets/*/assessment.md"):
    asm = "y"
    m = re.search(r"VERDICT:\s*\**\s*(\w+)", open(f, errors="replace").read())
    if m: verdict = m.group(1)
say = res.get("result", "") or ""
built = calls.get("implementer", 0) or inline or sc.get("where", "none") != "none"
asked = "y" if ("clarify" in ev or (not built and "?" in say)) else "-"
print("%-14s %-4s %-18s %-5s %-5s %-6s %-4d %-3d %-3d %-18s %-18s %-3d %-3d %-4s %-4s %-9s %-5s %s" % (
    os.path.basename(o), "PASS" if sc.get("where", "none") != "none" else "fail", sc.get("where", "?"),
    ex.get("wall", "-"), res.get("num_turns", "-"), "$%.2f" % res.get("total_cost_usd", 0),
    ev.count("intake"), ev.count("clarify"), ev.count("verdict"), dstr, cstr, inline,
    ev.count("done"), read, asm, verdict, asked,
    ("ERR:" + str(res.get("subtype"))) if res.get("is_error") or not res else res.get("subtype", "")))
PY
}

n=0
[ ${#ARM[@]} -gt 0 ] && for l in "${!ARM[@]}"; do for k in $(seq 1 "$K"); do
  run_one "$l" "$k" & n=$((n+1)); [ $((n % JOBS)) -eq 0 ] && wait
done; done; wait

# held = held-out oracle passed on the delivered change; where = first place it
# passed (main = landed; a lane worktree or branch = handed over, not merged). rows: intake/clarify/verdict counts from
# the board; journal = dispatched rows by persona; calls = Agent/Task calls the
# router actually made (journal < calls means it skipped the journal); inl = .py
# edits the router made itself; done = done rows; rd/asm = reading.md /
# assessment.md written; asked = stopped on a question instead of building.
{ printf '%-14s %-4s %-18s %-5s %-5s %-6s %-4s %-3s %-3s %-18s %-18s %-3s %-3s %-4s %-4s %-9s %-5s %s\n' \
    run held where secs turns cost int clr vrd journal calls inl don rd asm verdict asked status
  for o in "$OUT"/*/; do [ -f "$o/exit.env" ] && row "$o"; done; } | tee "$OUT/scorecard.txt"
