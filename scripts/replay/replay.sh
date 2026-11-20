#!/usr/bin/env bash
# Replay past asks through a plugin and keep what the session did, so an
# instruction change can be measured before and after on real asks. Works for
# any plugin in this repo; what "did the right thing" means is the caller's to
# score from the output (see README.md beside this file).
#
#   bash scripts/replay/replay.sh <set-dir> <source-repo> <out-dir> [case ...]
#
# A set is a directory of cases, one directory each, kept OUTSIDE this repo
# (real asks name real systems):
#   <case>/ask.md    the ask, verbatim
#   <case>/commit    the source-repo commit the ask was made against, or
#   <case>/tree/     a folder to use as the project instead: a made-up situation
#                    that is no commit of any repo. One or the other, never both.
#                    It is copied as it stands: files, folders, and links as
#                    links, never followed. A link must be relative and stay
#                    inside tree/; one that is absolute or leads out refuses
#                    the case, as does a .git anywhere inside. With only such cases,
#                    <source-repo> may be given as -. A case with tree/ that
#                    cannot be run is removed from the out dir and fails the call.
#   <case>/after.md  optional: the follow-up turn in post-compaction mode
#   anything else    copied to the output as is (a kind, an answer key), unless
#                    it carries the name of an output file below
#
# Env, required: REPLAY_PLUGIN_DIR (the plugin under test, a working tree),
# unless REPLAY_CANDIDATE is set: a preferences file can be tested with no plugin.
# Env, optional: REPLAY_CANDIDATE (a file to use as the session's user-level
# CLAUDE.md in place of the caller's own, which is then not carried: the two
# never run together. It must be a regular file with text in it. One copy is taken at
# startup, so every run of the call gets the same text, and the load check below
# covers it like any other instruction file), REPLAY_PREFIX (text sent before the ask, such as a slash
# command and a space), REPLAY_MODEL (opus), REPLAY_EFFORT (low), REPLAY_K (runs
# per case, 1), REPLAY_JOBS (parallel sessions, 4), REPLAY_BUDGET_USD (per
# session, 4; 8 in post-compaction mode), REPLAY_TIMEOUT (seconds per session,
# 900; 2700 in post-compaction mode), REPLAY_ALLOW_AGENTS (comma-separated
# read-only subagents that may really run; every other dispatch is recorded and
# refused), REPLAY_CARRY_SKILLS (space-separated names under ~/.claude/skills to
# copy into the sandbox), REPLAY_IGNORE (repo-relative prefix that is run state,
# not project work; default .agents/), REPLAY_JOURNAL (repo-relative path of an
# append-only log the plugin writes; its new rows are kept per turn),
# REPLAY_KEEP (space-separated repo-relative paths to copy out after each
# session, each to <out>/<its last name>; regular files only, links never
# followed), REPLAY_SRT (the sandbox runtime to use; default `srt` on PATH).
#
# An existing <out-dir>/<case>.<k> is replaced, never added to.
#
# Post-compaction mode, REPLAY_POSTCOMPACT=1: one process runs three turns
# (turns.py): the ask, then `/compact`, then after.md (default below).
#
# Output, per run, in <out-dir>/<case>.<k>/:
#   turn1.md result.json say.md   what was sent, the result event, the closing message
#   guard.jsonl                   every tool call the guard judged, allowed or refused
#   transcript.jsonl              the session transcript
#   changed-files.txt             project files that differ from the snapshot, as
#                                 its own git reports them, one name per line; a
#                                 control character in a name shows as "?".
#                                 Every file, if git cannot compare at all
#   journal.jsonl                 rows added to REPLAY_JOURNAL
#   post-compaction mode adds compact.result.json, guard.compact.jsonl,
#   turn2.result.json, turn2.say.md, guard.turn2.jsonl, journal.turn2.jsonl,
#   turn.stream.jsonl, compact.md, after.md; journal.jsonl then holds turn 1 only
#   settings.json stderr.txt      the hook wiring used, and the CLI's stderr
#   loaded.jsonl                  one row per instruction file the session loaded
#   facts.json                    what the runner knows about the run, for a
#                                 program to read: see README.md. No verdict.
#   noload.txt                    only when an instruction file that should have
#                                 loaded did not: its name. The run is marked
#                                 "noload" in the summary and the runner exits 3.
#                                 Checked: a CLAUDE.md in the throwaway HOME, at
#                                 the snapshot's root or in its .claude/. Not
#                                 checked: a repo with only AGENTS.md (the load
#                                 hook does not fire for it), rules files, and
#                                 whether a file loaded again after a compaction
# and <out-dir>/summary.txt, one line per run.
#
# The snapshot and the throwaway HOME go under TMPDIR (default /tmp): where is
# the caller's choice. A run measured without the replayed repo's CLAUDE.md, or
# without the operator's, is not the run that was asked for, so that is checked
# per run from the session's own load record and its transcript.
#
# Safety. Each session runs inside Anthropic's sandbox runtime (`srt`, the
# boundary Claude Code's own sandbox is built on: bubblewrap on Linux, Seatbelt
# on macOS), with a policy this runner writes per session:
#   - it can read the system's programs (/usr, /etc, a Homebrew or Nix prefix),
#     the CLI, the plugin under test, this harness, and its own snapshot,
#     throwaway HOME and log directory. Nothing else: not the caller's home,
#     /tmp, /run, the source repo, the set or the out dir;
#   - it can write only the snapshot, the throwaway HOME and the log directory.
#     On Linux the runtime shares one more path with the machine, /tmp/claude,
#     while it exists: the runner refuses to start, or to start a further
#     session, if it does;
#   - it has no network of its own. Every connection goes through the runtime's
#     proxy, which passes only the model's hosts (api.anthropic.com, claude.ai,
#     platform.claude.com). This machine's services and sockets are out of reach;
#   - it has its own process table, so no other process's environment is
#     readable, and an environment built from nothing: HOME, PATH, TERM, LANG,
#     TMPDIR, the model login and the proxy settings the runtime adds;
#   - the time limit runs inside the sandbox, so nothing a session started
#     outlives it, and an interrupted runner kills its sandboxes by name.
# The runner copies results out itself, never following a link the session
# left, and once a session has run, runs git on the snapshot only inside the sandbox, because the
# snapshot's git configuration is the session's to edit.
# Not limited: the memory and disk a session can fill inside its sandbox.
# The snapshot is a `git archive` (tracked files only, no remote), or a copy of
# the case's tree/, either way made with the caller's git configuration switched
# off so no filter, hook or signer of theirs runs.
# What the sandbox does not cover: the session holds the model login and talks
# to the model, so what it can read (the snapshot, the plugin, the operator's
# CLAUDE.md or the candidate in its place) goes to the model provider, as in any session, and tools the
# provider runs on its side (web search) are a way out. guard.py refuses those,
# the connected services that come with the login (also switched off by
# ENABLE_CLAUDEAI_MCP_SERVERS=false), dispatches and any tool it does not know.
# The guard is best effort (it pattern-matches commands), never the boundary.
# It blocks the tool when it errors, times out or cannot start, which needs
# Claude Code 2.1.295 or later, checked below.
# Tools installed under the caller's home are not on the session's PATH.
# The runtime is a beta: tested with 0.0.82 on Linux. macOS is untested and
# may not work: the readable list above is Linux's, and there the runtime
# shares /private/tmp/claude whether or not it exists.
# Without a usable runtime there is no boundary, only the scrubbed environment
# and the guard: the session runs as you. The runner refuses to start that way
# unless REPLAY_UNCONFINED=1.
#
# Claude Code only: Codex and OpenCode would each need their own driver.
# Reporting only; never a CI gate. Self-skips without claude/auth/python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SET="${1:?set dir}"; SRC="${2:?source repo}"; OUT="${3:?out dir}"; shift 3
case "${REPLAY_JOBS:-4}" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) echo "replay: REPLAY_JOBS must be a whole number from 1 to 999, written without a leading zero (got: ${REPLAY_JOBS:-})" >&2; exit 2 ;; esac
command -v claude >/dev/null 2>&1 || { echo "(skip replay: claude not on PATH)"; exit 0; }
# Only logins the sandboxed session can be handed: a key, a token, or the credential file.
[ -n "${ANTHROPIC_API_KEY:-}" ] || [ -f "$HOME/.claude/.credentials.json" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
  || { echo "(skip replay: no live auth)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "(skip replay: python3 absent)"; exit 0; }
[ "$(df -Pk "${TMPDIR:-/tmp}" | awk 'NR==2{print $4}')" -ge 1048576 ] || { echo "(skip replay: low tmp space)"; exit 0; }
# A source repo of - means there is none: every case then brings its own tree/.
[ "$SRC" != - ] || SRC=""
[ -d "$SET" ] && { [ -z "$SRC" ] || git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; } || { echo "replay: need a set dir and a git source repo" >&2; exit 2; }
# The candidate preferences file. Empty or missing would run with no such file at
# all and still count as measured, so that is refused here, not found out later.
CAND="${REPLAY_CANDIDATE:-}"
[ -z "$CAND" ] || { [ -f "$CAND" ] && grep -q '[^[:space:]]' "$CAND" 2>/dev/null; } || { echo "replay: REPLAY_CANDIDATE is not a regular file with text in it ($CAND)" >&2; exit 2; }
# A plugin is required unless a candidate file is what is under test; one that is named must exist.
if [ -n "${REPLAY_PLUGIN_DIR:-}" ]; then
  [ -d "$REPLAY_PLUGIN_DIR" ] || { echo "replay: REPLAY_PLUGIN_DIR is not a directory ($REPLAY_PLUGIN_DIR)" >&2; exit 2; }
else
  [ -n "$CAND" ] || { echo "replay: set REPLAY_PLUGIN_DIR to the plugin under test" >&2; exit 2; }
fi
# The guard only blocks on its own failure from 2.1.295 on; an older CLI would run the tool.
ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$(printf '%s\n' 2.1.295 "${ver:-0}" | sort -V | head -1)" = 2.1.295 ] \
  || { echo "replay: needs Claude Code 2.1.295 or later (found ${ver:-none})" >&2; exit 2; }
CLAUDE_BIN="$(readlink -f "$(command -v claude)" 2>/dev/null || command -v claude)"
TIMEOUT="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$TIMEOUT" ] || { echo "replay: needs timeout (GNU coreutils)" >&2; exit 2; }
REAL_HOME="$(cd "$HOME" 2>/dev/null && pwd -P)"
[ -n "$REAL_HOME" ] || { echo "replay: HOME is not a directory" >&2; exit 2; }
[ -z "$SRC" ] || SRC="$(cd "$SRC" && pwd -P)"; SET="$(cd "$SET" && pwd -P)"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"
[ -n "$OUT" ] || { echo "replay: cannot use the out dir" >&2; exit 2; }
case "$HERE$OUT" in *\'*|*\"*|*\\*) echo "replay: a quote or backslash in the harness or out dir path is not supported" >&2; exit 2 ;; esac
# The source repo's whole checkout and its git directory are hidden, not just the
# directory named: a worktree keeps its history elsewhere.
SRC_HIDE=()
if [ -n "$SRC" ]; then SRC_HIDE=("$SRC")
  for d in "$(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null)" "$(git -C "$SRC" rev-parse --git-common-dir 2>/dev/null)"; do
    d="$(cd "$SRC" && cd "$d" 2>/dev/null && pwd -P)" && [ -n "$d" ] && [ "$d" != / ] && SRC_HIDE+=("$d")
  done
fi

# The sandbox runtime (REPLAY_SRT, or `srt` on PATH) is probed after the run
# directory exists, by running it: present but not permitted here counts as absent.
SRT="${REPLAY_SRT:-$(command -v srt 2>/dev/null || true)}"

MODEL="${REPLAY_MODEL:-opus}"; EFFORT="${REPLAY_EFFORT:-low}"; K="${REPLAY_K:-1}"
PDIR=""; [ -z "${REPLAY_PLUGIN_DIR:-}" ] || PDIR="$(cd "$REPLAY_PLUGIN_DIR" && pwd -P)" || { echo "replay: cannot enter REPLAY_PLUGIN_DIR ($REPLAY_PLUGIN_DIR)" >&2; exit 2; }; JOBS="${REPLAY_JOBS:-4}"
PC="${REPLAY_POSTCOMPACT:-}"; [ "$PC" = 0 ] && PC=""
AFTER_DEFAULT="Continue. What is the state of this work and what is your next step?"
BUDGET="${REPLAY_BUDGET_USD:-$([ -n "$PC" ] && echo 8 || echo 4)}"; GUARD="$HERE/guard.py"
LIMIT="${REPLAY_TIMEOUT:-$([ -n "$PC" ] && echo 2700 || echo 900)}"
IGNORE="${REPLAY_IGNORE-.agents/}"; JOURNAL="${REPLAY_JOURNAL:-}"
# A plugin may link to skills that live beside it in its checkout: those are
# put back for the session too, read-only.
PLUG_LINKS=()
while IFS= read -r d; do
  d="$(readlink -f "$d" 2>/dev/null)"; case "$d/" in "$PDIR"/*|/) ;; *) [ -e "$d" ] && PLUG_LINKS+=("$d") ;; esac
done < <([ -z "$PDIR" ] || find "$PDIR" -maxdepth 3 -type l 2>/dev/null)
# The set and the out dir are hidden from the session whatever else is
# readable, so nothing the session needs may sit inside them.
case "$OUT:$SET" in /:*|*:/) echo "replay: the set and the out dir cannot be /" >&2; exit 2 ;; esac
for d in ${PDIR:+"$PDIR"} "$HERE" "$CLAUDE_BIN" "$(cd "${TMPDIR:-/tmp}" && pwd -P)"; do case "$d/" in "$OUT"/*|"$SET"/*)
  echo "replay: the set and the out dir must not contain the plugin, the harness, the CLI or TMPDIR ($d)" >&2; exit 2 ;; esac; done
[ $# -gt 0 ] && CASES="$*" || CASES="$(cd "$SET" && ls -d */ 2>/dev/null | tr -d /)"

# Every sandbox nests under one directory made here, in the parent shell, so one
# trap removes them all whichever subshell made them.
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/replay.XXXXXXXX")" || exit 2
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
# Every sandbox carries this run's directory in its arguments. Killing by that
# name is what stops them, whether or not a sandbox dies with the runner.
reap(){ [ -n "$RUN_DIR" ] && pkill -KILL -f -- "$RUN_DIR/t\." 2>/dev/null; return 0; }
trap 'reap; cd /; [ -n "$RUN_DIR" ] && rm -rf "$RUN_DIR"' EXIT
# An interrupt must stop the paid sessions too (reap, then the EXIT trap). The
# time limit runs INSIDE the sandbox, as its first process: when it ends the
# session, the sandbox ends with it and nothing the session started survives.
trap 'reap; exit 130' INT
trap 'reap; exit 143' TERM
# The caller's git configuration (filters, hooks, signing) must not run on the snapshot.
cgit(){ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
# The run directory's path is written into each session's settings and matched in its records.
case "$RUN_DIR" in *\'*|*\"*|*\\*) echo "replay: a quote or backslash in TMPDIR is not supported" >&2; exit 2 ;; esac
mk_tmp(){ mktemp -d "$RUN_DIR/t.XXXXXXXX"; }
# One copy of the candidate for the whole call: a file edited mid-run cannot make
# two runs differ, and the hash in facts.json is of the text that ran.
CAND_SHA=""
if [ -n "$CAND" ]; then
  cp -L "$CAND" "$RUN_DIR/candidate.md" && [ -s "$RUN_DIR/candidate.md" ] || { echo "replay: cannot read REPLAY_CANDIDATE ($CAND)" >&2; exit 2; }
  CAND="$RUN_DIR/candidate.md"
  CAND_SHA="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CAND")"
  [ "${#CAND_SHA}" = 64 ] || { echo "replay: cannot hash REPLAY_CANDIDATE" >&2; exit 2; }
fi
# Read a file the session could have written, only if it is a regular file that
# really lives under <root>: the session may have left a link pointing elsewhere.
# take copies it to <dest> (and writes nothing when it is not there); emit prints it.
real_under(){ # <root> <file> -> prints the real path, or fails
  local real; real="$(readlink -f "$2" 2>/dev/null)" || return 1
  case "$real" in "$1"/*) [ -f "$real" ] && printf '%s\n' "$real" ;; *) return 1 ;; esac; }
emit(){ local r; r="$(real_under "$1" "$2")" && head -c 268435456 "$r"; }       # capped: the session chose its size
take(){ local r; r="$(real_under "$1" "$2")" && head -c 268435456 "$r" > "$3"; }
# A number read from a file the session could write: digits, or 0. Never let
# such text reach shell arithmetic as anything else (it would be evaluated).
num(){ case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
jget(){ python3 -c 'import json,sys;v=json.load(open(sys.argv[1]));print(list(v["_lines"].values())[0] if sys.argv[2]=="_lines" else v.get("result",""))' "$1" "$2" 2>/dev/null; }

# The caller may itself be an agent session whose PATH carries an INSTALLED copy of
# the plugin's helpers; the replay must run the helpers of the plugin under test.
CLEAN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/\.claude/plugins/' -e '/plugins/[^/]*/bin$' | paste -sd: -)"

# Write a session's sandbox policy: <file> <read-only paths...> -- <writable
# paths...> -- <hidden paths...> -- <paths never writable...>. Every path is taken literally, never as a pattern.
SYS_READ=(); for d in /usr /etc /nix /opt/homebrew /home/linuxbrew; do d="$(readlink -f "$d" 2>/dev/null)" && [ -d "$d" ] && SYS_READ+=("$d"); done
RG=(); command -v rg >/dev/null 2>&1 || RG=("$CLAUDE_BIN")      # the CLI carries a ripgrep of its own
policy(){ python3 - "${RG[0]:-}" "$@" <<'POLICY'
import json, sys
rg, out, groups = sys.argv[1], sys.argv[2], [[]]
for a in sys.argv[3:]:
    groups.append([]) if a == "--" else groups[-1].append({"path": a, "literal": True})
read, write, hide, lock = (groups + [[], [], []])[:4]
cfg = {"network": {"allowedDomains": ["api.anthropic.com", "claude.ai", "platform.claude.com"], "deniedDomains": []},
       "filesystem": {"denyRead": ["/"] + hide, "allowRead": read + write, "allowWrite": write, "denyWrite": lock}}
if rg: cfg["ripgrep"] = {"command": rg, "argv0": "rg"}
json.dump(cfg, open(out, "w"))
POLICY
}
# On Linux the runtime keeps this path readable and writable from inside every
# sandbox it starts while the path exists on the machine. Checked at startup
# and again before each session, since the runtime decides per sandbox.
shared(){ local d; for d in /tmp/claude /private/tmp/claude; do [ ! -e "$d" ] && [ ! -L "$d" ] || {
  echo "replay: $d exists, and the sandbox runtime shares that path with every session: remove it first" >&2; return 1; }; done; }
if [ -n "$SRT" ]; then
  shared || exit 2
  # The runtime's proxy listens on sockets under TMPDIR, whose path has a short limit.
  [ "${#RUN_DIR}" -le 60 ] || { echo "replay: TMPDIR is too long a path for the sandbox's sockets ($RUN_DIR)" >&2; exit 2; }
  SRT="$(readlink -f "$SRT")"; SRT_PKG="$(dirname "$(dirname "$SRT")")"; mkdir -p "$RUN_DIR/probe"
  policy "$RUN_DIR/probe/srt.json" "${SYS_READ[@]}" "$SRT_PKG" "$RUN_DIR/probe"
  why="$( { cd "$RUN_DIR/probe" && TMPDIR="$RUN_DIR/probe" "$SRT" --settings srt.json -- true; } 2>&1 >/dev/null )" \
    || { echo "replay: the sandbox runtime did not start: $(printf '%s' "$why" | tail -n 3 | tr '\n' ' ' | cut -c1-400)" >&2; SRT=""; }
fi
[ -n "$SRT" ] || [ "${REPLAY_UNCONFINED:-}" = 1 ] || {
  echo "replay: no usable sandbox runtime, so no sandbox boundary (npm install -g @anthropic-ai/sandbox-runtime; Linux also needs bubblewrap, socat and ripgrep); set REPLAY_UNCONFINED=1 to run without one (see the header)" >&2; exit 2; }
[ -n "$SRT" ] || echo "replay: UNCONFINED: no sandbox boundary, only a scrubbed environment and a best-effort guard" >&2

RESERVED=" commit after.md turn1.md result.json say.md guard.jsonl transcript.jsonl changed-files.txt journal.jsonl settings.json stderr.txt compact.result.json guard.compact.jsonl turn2.result.json turn2.say.md guard.turn2.jsonl journal.turn2.jsonl turn.stream.jsonl compact.md loaded.jsonl noload.txt facts.json "
for d in ${REPLAY_KEEP:-}; do d="${d%/}"; RESERVED+="${d##*/} "; done

run_one(){ # <case> <k>
  local c="$1" k="$2" cd_="$SET/$1" o="$OUT/$1.$2" home repo log cfg commit="" s f d n t1="" t2=""
  # The project comes from a commit of the source repo, or from the case's own tree/.
  # A tree/ case, or any case with no source repo to look in, that cannot be run
  # fails the call and leaves no older output behind to be read as this call's.
  drop(){ echo "replay: $c: $1" >&2; rm -rf "${OUT:?}/$c.$k"; echo "$c.$k" >> "$RUN_DIR/failed"; }
  [ -f "$cd_/ask.md" ] && { [ -f "$cd_/commit" ] || [ -d "$cd_/tree" ]; } || { echo "replay: $c lacks ask.md, or a commit or a tree/" >&2; return; }
  if [ -f "$cd_/commit" ] && [ -d "$cd_/tree" ]; then
    drop "has both a commit and a tree/: keep one"; return
  elif [ -f "$cd_/commit" ] && [ -z "$SRC" ]; then
    drop "commit is not a commit of the source repo"; return
  elif [ -f "$cd_/commit" ]; then
    commit="$(cgit -C "$SRC" rev-parse --verify --quiet --end-of-options "$(tr -d ' \n' < "$cd_/commit")^{commit}")" \
      || { echo "replay: $c: commit is not a commit of the source repo" >&2; return; }
  elif [ -L "$cd_/tree" ] || [ -n "$(find "$cd_/tree" -iname .git -print -quit 2>&1)" ]; then
    drop "tree/ is a link, cannot be read, or has a .git inside"; return
  fi
  # Four directories per run. The session can write its snapshot, its HOME and
  # its log directory; it can only read cfg. The output directory is the
  # caller's: the session never sees it. What lands there is the session's
  # standard output through a size cap, and copies the runner makes.
  home="$(mk_tmp)"; repo="$(mk_tmp)"; log="$(mk_tmp)"; cfg="$(mk_tmp)"
  rm -rf "${OUT:?}/$c.$k"; mkdir -p "$o" "$home/.claude/skills" "$home/tmp"
  [ -z "$SRT" ] || shared || { echo "replay: $c.$k not run" >&2; echo "$c.$k" >> "$RUN_DIR/failed"; return; }
  # The case's extra files, except any named like an output: it could stand in for one the session never left.
  for f in "$cd_"/*; do case "$RESERVED" in *" ${f##*/} "*) ;; *) [ -f "$f" ] && cp "$f" "$o/" ;; esac; done
  if [ -n "$commit" ]; then
    cgit -C "$SRC" archive "$commit" | tar -x -C "$repo" || { echo "replay: $c: cannot snapshot $commit" >&2; return; }
  else
    # A plain folder, copied as it stands. A link is copied as a link and never
    # followed, and only if it is relative and stays inside the folder (a
    # CLAUDE.md that points at AGENTS.md): a hand-built folder is where a stray
    # link to somewhere else on the machine would arrive, and the sandbox can read
    # more than the snapshot, so such a link stops the case instead of resting on it.
    # Anything else that is not a file or a folder is left out; anything unreadable stops the case.
    python3 - "$cd_/tree" "$repo" <<'TREE' || { drop "cannot copy tree/"; return; }
import os, shutil, stat, sys
src, dst = sys.argv[1], sys.argv[2]
def stop(e): raise e
root = os.path.realpath(src)
def inside(p):
    # A relative link that stays in the folder both ways: read from where it sits (that is where it will
    # point once copied, so "../tree/x" from the top is out), and followed all the way through other links.
    target = os.readlink(p)
    lands = os.path.normpath(os.path.join(os.path.dirname(os.path.relpath(p, src)), target))
    return (not os.path.isabs(target) and lands != ".." and not lands.startswith(".." + os.sep)
            and (os.path.realpath(p) + os.sep).startswith(root + os.sep))
try:
    for top, dirs, files in os.walk(src, followlinks=False, onerror=stop):
        to = os.path.join(dst, os.path.relpath(top, src)); os.makedirs(to, exist_ok=True)
        for f in dirs + files:
            p = os.path.join(top, f); mode = os.lstat(p).st_mode
            if stat.S_ISLNK(mode):
                if not inside(p): sys.exit("replay: a link in tree/ is absolute or leads outside it: " + os.path.relpath(p, src))
                os.symlink(os.readlink(p), os.path.join(to, f))
            elif stat.S_ISREG(mode): shutil.copy(p, os.path.join(to, f), follow_symlinks=False)   # keeps the executable bit
        dirs[:] = [x for x in dirs if not os.path.islink(os.path.join(top, x))]
except OSError as e:
    sys.exit("replay: tree/ cannot be read: " + str(e.filename or e))
TREE
  fi
  # Project-level harness config can start servers and hooks of its own: drop it.
  ( cd "$repo" && { [ ! -L .claude ] || rm -f .claude; } && rm -rf .mcp.json .claude/settings.json .claude/settings.local.json .envrc )
  ( cd "$repo" && cgit init -q && git config user.email t@t && git config user.name t \
      && { [ -z "$IGNORE" ] || printf '%s\n' "$IGNORE" >> .git/info/exclude; } \
      && cgit add --all >/dev/null 2>&1 && cgit commit -qm snapshot $([ -n "$commit" ] || echo --allow-empty) ) \
    || { [ -n "$commit" ] && echo "replay: $c: cannot commit the snapshot" >&2 || drop "cannot commit the snapshot"; return; }
  # The snapshot's own commit, remembered now: what the session changed is measured against it,
  # whatever the session does to the history afterwards.
  local snap; snap="$(cd "$repo" && cgit rev-parse --verify --quiet HEAD)"
  # Only the model login, the operator's standing preferences (they shape how a
  # session asks) and the named skills are carried into the sandbox HOME.
  # A candidate takes the place of those preferences: the caller's own are then left behind.
  for f in .credentials.json CLAUDE.md; do
    [ "$f" = CLAUDE.md ] && [ -n "$CAND" ] && continue
    [ -f "$HOME/.claude/$f" ] && cp -L "$HOME/.claude/$f" "$home/.claude/$f" 2>/dev/null
  done
  [ -z "$CAND" ] || cp "$CAND" "$home/.claude/CLAUDE.md" || { echo "replay: $c.$k not run: cannot place the candidate" >&2; echo "$c.$k" >> "$RUN_DIR/failed"; return; }
  for s in ${REPLAY_CARRY_SKILLS:-}; do
    [ -d "$HOME/.claude/skills/$s" ] && cp -RL "$HOME/.claude/skills/$s" "$home/.claude/skills/" 2>/dev/null
  done
  # The hook wiring is read-only to the session, and so is its user settings
  # file, so it cannot unhook the guard from there.
  echo '{}' > "$home/.claude/settings.json"
  cat > "$cfg/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"python3 '$GUARD'","timeout":10,"onFailure":"block"}]}],"InstructionsLoaded":[{"hooks":[{"type":"command","command":"paste -s -d ' ' - >> '$log/loaded.jsonl'","timeout":10}]}]}}
JSON
  cp "$cfg/settings.json" "$o/settings.json"
  # The instruction files this session should load, each with what it resolves
  # to, both as they stand before the session can change them.
  local expect=(); for f in "$home/.claude/CLAUDE.md" "$repo/CLAUDE.md" "$repo/.claude/CLAUDE.md"; do
    [ -s "$f" ] && expect+=("$f" "$(readlink -f "$f")"); done
  # The snapshot may carry a tracked copy of the journal; keep only what this run adds.
  local journal="${JOURNAL:+$repo/$JOURNAL}" base=0
  [ -n "$journal" ] && [ -f "$journal" ] && base="$(num "$(wc -l < "$journal" | tr -d ' ')")"
  local cargs=(-p --model "$MODEL" --effort "$EFFORT" ${PDIR:+--plugin-dir "$PDIR"} --settings "$cfg/settings.json"
               --max-budget-usd "$BUDGET" --allowedTools "Read,Grep,Glob,Write,Edit,Bash,Agent,Task,Skill")
  # The policy: what the session may read, then write, then what stays hidden
  # even if it sits inside something readable.
  local box=() sk=""
  if [ -n "$SRT" ]; then
    sk="$(mk_tmp)"
    policy "$cfg/srt.json" "${SYS_READ[@]}" "$CLAUDE_BIN" "$SRT_PKG" ${PDIR:+"$PDIR"} ${PLUG_LINKS[@]+"${PLUG_LINKS[@]}"} "$HERE" "$cfg" "$sk" \
           -- "$repo" "$home" "$log" -- "$SET" "$OUT" ${SRC_HIDE[@]+"${SRC_HIDE[@]}"} -- "$home/.claude/settings.json"
    box=("$SRT" --settings "$cfg/srt.json" --)
  fi
  # The environment is built from nothing BEFORE the sandbox starts, so the
  # sandbox's own first process carries none of the caller's variables either.
  # TMPDIR outside is where the runtime puts its proxy sockets; inside it is reset.
  # /usr/bin/env, not `env`: an interactive caller's shell may define an `env` function.
  inbox(){ ( exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-    # nothing the caller left open is handed on
      cd "$repo" && /usr/bin/env -i HOME="$home" PATH="$CLEAN_PATH" TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" \
      TMPDIR="${sk:-$home/tmp}" "$@" ); }
  local tmp=(/usr/bin/env TMPDIR="$home/tmp" CLAUDE_CODE_TMPDIR="$home/tmp")
  session(){ inbox ENABLE_CLAUDEAI_MCP_SERVERS=false \
      ${ANTHROPIC_API_KEY:+ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"} \
      ${CLAUDE_CODE_OAUTH_TOKEN:+CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"} \
      ${ANTHROPIC_DEFAULT_OPUS_MODEL:+ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL"} \
      REPLAY_ALLOW_AGENTS="${REPLAY_ALLOW_AGENTS:-}" REPLAY_LOG="$log/guard.jsonl" REPLAY_ROOTS="$repo:$home${PDIR:+:$PDIR}" \
      ${box[@]+"${box[@]}"} "${tmp[@]}" "$TIMEOUT" -k 10 "$1" "${@:2}"; }
  { printf '%s' "${REPLAY_PREFIX:-}"; cat "$cd_/ask.md"; } > "$log/turn1.md"; cp "$log/turn1.md" "$o/turn1.md"
  if [ -z "$PC" ]; then
    session "$LIMIT" "$CLAUDE_BIN" "${cargs[@]}" --output-format json < "$o/turn1.md" 2> "$log/stderr.txt" | head -c 268435456 > "$o/result.json"
    take "$log" "$log/guard.jsonl" "$o/guard.jsonl"
  else
    printf '/compact\n' > "$log/compact.md"
    if [ -f "$cd_/after.md" ]; then cp "$cd_/after.md" "$log/after.md"; else printf '%s\n' "$AFTER_DEFAULT" > "$log/after.md"; fi
    cp "$log/compact.md" "$log/after.md" "$o/"
    session "$LIMIT" python3 "$HERE/turns.py" --split "$log/guard.jsonl" ${journal:+--lines "$journal"} \
        "$log/turn" "$log/turn1.md" "$log/compact.md" "$log/after.md" -- "$CLAUDE_BIN" "${cargs[@]}" > /dev/null 2> "$log/stderr.txt"
    # <file the session side wrote>:<its name in the output>
    for f in turn.1.json:result.json turn.2.json:compact.result.json turn.3.json:turn2.result.json turn.stream.jsonl:turn.stream.jsonl \
             guard.jsonl.turn1:guard.jsonl guard.jsonl.turn2:guard.compact.jsonl guard.jsonl.turn3:guard.turn2.jsonl; do
      take "$log" "$log/${f%%:*}" "$o/${f##*:}"
    done
    t1="$(jget "$o/result.json" _lines)"; t2="$(jget "$o/compact.result.json" _lines)"
    jget "$o/turn2.result.json" result > "$o/turn2.say.md"
  fi
  if [ -n "$journal" ]; then
    # In post-compaction mode journal.jsonl is turn 1 only, to match guard.jsonl,
    # and journal.turn2.jsonl is what was added after the compaction.
    # A turn that never finished left no line count: its rows stay with the turn
    # that wrote them, so a run cut short in turn 1 still shows what turn 1 did.
    n=$(( $(num "$t1") - $(num "$base") )); [ "$n" -gt 0 ] || n=0
    emit "$repo" "$journal" | tail -n +"$(( base + 1 ))" | { [ -n "$t1" ] && head -n "$n" || cat; } > "$o/journal.jsonl"
    [ -z "$PC" ] || { [ -n "$t2" ] && emit "$repo" "$journal" | tail -n +"$(( $(num "$t2") + 1 ))"; } > "$o/journal.turn2.jsonl"
  fi
  for f in "$home"/.claude/projects/*/*.jsonl; do emit "$home" "$f"; done > "$o/transcript.jsonl" 2>/dev/null
  # What the session changed since the snapshot, committed or not, as the
  # snapshot's own git reports it: what differs from the snapshot's commit (a
  # renamed file under both names), plus files git neither tracks nor ignores.
  # The repo's git configuration is now the session's, so git runs inside the
  # sandbox, and a session that changes what git reports can shorten the list.
  # While the sandbox is up it shows placeholders over paths it protects
  # (.bashrc, .mcp.json), so a new file counts only if it is still there after.
  # Names arrive NUL-ended, each as it is; in the list, a control character in a
  # name shows as "?". If git cannot make the comparison at all (the session
  # removed the snapshot's commit or the repository), every file is listed.
  # The list is taken whole first: the placeholders are gone only once the sandbox has ended.
  rm -f "$cfg/nocompare"
  inbox ${box[@]+"${box[@]}"} "${tmp[@]}" "$TIMEOUT" -k 5 60 sh -c \
      'git diff --name-only --no-renames -z "$1" && printf "//\0" && git ls-files -z --others --exclude-standard && printf "/ok\0"' sh "$snap" 2>/dev/null > "$cfg/changed.z"
  { LC_ALL=C; n=""; ok=""; while IFS= read -r -d '' f; do
        [ "$f" = // ] && { n=1; continue; }; [ "$f" = /ok ] && { ok=1; continue; }
        [ -z "$n" ] || [ -e "$repo/$f" ] || [ -L "$repo/$f" ] || continue; [ -z "$f" ] || printf '%s\n' "${f//[[:cntrl:]]/?}"; done
      [ -n "$ok" ] || : > "$cfg/nocompare"; } < "$cfg/changed.z" \
    | awk -v p="$IGNORE" 'p == "" || index($0, p) != 1' | LC_ALL=C sort -u > "$o/changed-files.txt"
  if [ -e "$cfg/nocompare" ]; then
    echo "replay: $c.$k: cannot compare the project with its snapshot: changed-files.txt lists every file" >&2
    ( cd "$repo" && find . -name .git -prune -o \( -type f -o -type l \) -print0 ) \
      | { LC_ALL=C; while IFS= read -r -d '' f; do f="${f#./}"; printf '%s\n' "${f//[[:cntrl:]]/?}"; done; } \
      | awk -v p="$IGNORE" 'p == "" || index($0, p) != 1' | LC_ALL=C sort -u > "$o/changed-files.txt"
  fi
  take "$log" "$log/stderr.txt" "$o/stderr.txt"
  # The load hook runs on its own time and may lose a row at session end, so the
  # transcript counts as well. In neither: the run did not have its instructions.
  # Loaded once is what is checked; a reload after a compaction is recorded
  # (load_reason "compact"), not required. Both records are the session's to
  # write: this catches a run that lost its instructions, not one that lies.
  take "$log" "$log/loaded.jsonl" "$o/loaded.jsonl"
  python3 - "$o" "$home" "$repo" ${expect[@]+"${expect[@]}"} > "$o/noload.txt" <<'LOADED'
import json, sys
o, home, repo, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
seen = set()
try:
    for l in open(o + "/loaded.jsonl", errors="replace"):
        try: seen.add(json.loads(l)["file_path"])
        except Exception: pass
except OSError: pass
try: said = open(o + "/transcript.jsonl", errors="replace").read()
except OSError: said = ""
for f, real in zip(want[0::2], want[1::2]):
    if f in seen or real in seen or ("Contents of " + f) in said: continue
    print("home/" + f[len(home) + 1:] if f.startswith(home + "/") else "repo/" + f[len(repo) + 1:])
LOADED
  if [ -s "$o/noload.txt" ]; then echo "$c.$k" >> "$RUN_DIR/failed"; else rm -f "$o/noload.txt"; fi
  jget "$o/result.json" result > "$o/say.md" || echo "(no result)" > "$o/say.md"
  # Copied by the runner as the caller, from files the session wrote: regular
  # files only, no link followed anywhere on the way, nothing large.
  python3 - "$repo" "$o" ${REPLAY_KEEP:-} <<'KEEP'
import os, shutil, stat, sys
repo, out = os.path.realpath(sys.argv[1]), sys.argv[2]
def ok(p):   # a regular file whose real path is itself: no link in any component
    try: st = os.lstat(p)
    except OSError: return False
    return stat.S_ISREG(st.st_mode) and st.st_size <= 5 << 20 and os.path.realpath(p) == p
for rel in sys.argv[3:]:
    src = os.path.normpath(os.path.join(repo, rel)); dst = os.path.join(out, os.path.basename(src))
    if not src.startswith(repo + os.sep) or os.path.realpath(src) != src: continue
    if ok(src):
        try: shutil.copyfile(src, dst, follow_symlinks=False)
        except OSError: pass
        continue
    for top, dirs, files in os.walk(src, followlinks=False):
        for f in files:
            p = os.path.join(top, f)
            if ok(p):
                t = os.path.join(dst, os.path.relpath(p, src))
                try: os.makedirs(os.path.dirname(t), exist_ok=True); shutil.copyfile(p, t, follow_symlinks=False)
                except OSError: pass
KEEP
  # What the runner knows about this run, for a program to read; no verdict. A
  # value read from a file the session could write is kept only as a finite
  # number, a yes or no, or, for the two lists the session reports about itself
  # (files loaded, models used), a few short names cut down to the characters a
  # path or a model name has. Those two lists are still the session's own words.
  # "noload" is the mark above, so the two agree. Written after the kept paths, so
  # a file the session left under this name cannot stand in for it.
  python3 - "$o" "$home" "$repo" "$c" "$k" "$MODEL" "$EFFORT" "${commit:+commit}" "$CAND_SHA" "${SRT:+1}" "${PC:+1}" "${PDIR:+1}" \
      ${expect[@]+"${expect[@]}"} > "$o/facts.json" <<'FACTS'
import json, os, re, sys
o, home, repo, case, k, model, effort, commit, cand, boxed, pc, plugin = sys.argv[1:13]
def name(f):   # where a file sat in the run, not the temporary path it had
    for root, tag in ((home, "home"), (repo, "repo")):
        if f.startswith(root + "/"): return tag + f[len(root):]
    return f
def count(p, keep=lambda l: l.strip()):
    try: return sum(1 for l in open(p, errors="replace") if keep(l))
    except OSError: return 0
try: r = json.load(open(o + "/result.json"))
except Exception: r = {}
if not isinstance(r, dict): r = {}
def num(key, scale=1):
    v = r.get(key)   # not NaN, not infinite, not a number too long to be one
    ok = isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and -1e12 < v < 1e12
    return (v if scale == 1 else v / scale) if ok else None
short = lambda t, n: re.sub(r"[^A-Za-z0-9._/@+:\[\]-]", "?", t[:n])
loaded = []
try:
    for l in open(o + "/loaded.jsonl", errors="replace"):
        try: f = short(name(json.loads(l)["file_path"]), 200)
        except Exception: continue
        if f not in loaded and len(loaded) < 50: loaded.append(f)
except OSError: pass
used = r.get("modelUsage")
json.dump({
    "case": case, "run": int(k), "model_asked": model, "effort": effort,
    "models_used": sorted(short(str(m), 80) for m in used)[:10] if isinstance(used, dict) else [],
    "source": "commit" if commit else "tree", "candidate_sha256": cand or None,
    "confined": bool(boxed), "postcompact": bool(pc), "plugin": bool(plugin),
    "expected": [name(f) for f in sys.argv[13::2]], "loaded": loaded, "noload": os.path.exists(o + "/noload.txt"),
    "is_error": r.get("is_error") if isinstance(r.get("is_error"), bool) else None,
    "cost_usd": num("total_cost_usd"), "turns": num("num_turns"), "seconds": num("duration_ms", 1000),
    "refused": count(o + "/guard.jsonl", lambda l: '"decision": "deny"' in l),
    "changed_files": count(o + "/changed-files.txt"),
}, sys.stdout, indent=1, allow_nan=False)
FACTS
  [ -s "$o/facts.json" ] || { rm -f "$o/facts.json"; echo "replay: $c.$k: could not write facts.json" >&2; }
}

n=0
for c in $CASES; do for k in $(seq 1 "$K"); do
  run_one "$c" "$k" & n=$((n+1)); [ $((n % JOBS)) -eq 0 ] && wait
done; done; wait

# One line per run from what every plugin has: refused = tool calls the guard
# refused, edits = project files changed, then the cost of the first turn.
printf '%-28s %-7s %-5s %-5s %-5s %s\n' run refused edits turns secs cost | tee "$OUT/summary.txt"
for o in "$OUT"/*/; do [ -d "$o" ] || continue; python3 - "${o%/}" <<'PY'
import json, os, sys
o = sys.argv[1]
def n(p, keep=lambda l: l.strip()):
    try: return sum(1 for l in open(p) if keep(l))
    except Exception: return 0
try: r = json.load(open(o + "/result.json"))
except Exception: r = {}
def f(k, fmt, scale=1):   # the session may have written this file: a field is a number or a dash
    v = r.get(k) if isinstance(r, dict) else None
    return fmt % (v / scale) if isinstance(v, (int, float)) and not isinstance(v, bool) and -1e12 < v < 1e12 else "-"
print("%-28s %-7d %-5d %-5s %-5s %s%s" % (os.path.basename(o), n(o + "/guard.jsonl", lambda l: '"decision": "deny"' in l),
      n(o + "/changed-files.txt"), f("num_turns", "%d"), f("duration_ms", "%d", 1000), f("total_cost_usd", "%.2f"),
      "  noload" if os.path.exists(o + "/noload.txt") else ""))
PY
done | LC_ALL=C tr -cd '[:print:]\n' | tee -a "$OUT/summary.txt"   # session-written text never reaches the terminal raw
# A run without its instructions, or one that was refused, is not a
# measurement: say so and fail. Only this call's runs count, not older ones in the out dir.
if [ -s "$RUN_DIR/failed" ]; then
  echo "replay: not measured (an instruction file did not load: see noload.txt; or the session was refused): $(sort -u "$RUN_DIR/failed" | tr '\n' ' ')" >&2; exit 3
fi
exit 0
