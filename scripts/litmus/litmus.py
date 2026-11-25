#!/usr/bin/env python3
"""litmus: did an edit to a CLAUDE.md or rules file change what agents do?

  litmus.py compare --old OLD.md --new NEW.md --cases DIR --model haiku
  litmus.py compare --old FILE.md --without "<sentence>" --cases DIR --model haiku
  litmus.py compare --old FILE.md --same --cases DIR --model haiku     (a file against itself)
  litmus.py probe --model haiku     which instruction files load, and that each safeguard fires
  litmus.py replay --old OLD.md --new NEW.md --cases DIR --model MODEL --effort high
        what a session with tools does under each wording (a measurement, no verdict)

Each case is asked alone, one question per session, against the old and the
new wording as pairs with the same option order. engine.py runs the sessions
(real delivery, throwaway home, empty environment, load check); judge.py turns
the pairs into `pass`, `regress` or `inconclusive`. This file reads cases,
grades answers, keeps the cache and the spend ledger, and prints the table.

A case is a folder holding case.toml:
  situation = "..."            what the agent faces, written as the user turn
  options   = ["...", "..."]   the actions it may choose from
  expect    = ["b"]            letters of the acceptable actions (a = first option)
  sections  = ["Heading"]      headings of the file this case exercises. Only
                               cases for headings the edit touches are run,
                               and no `pass` is given while a touched heading
                               has no case in the run: that is `inconclusive`.
  kind      = "single-turn"    other kinds are skipped here

Exit: 0 pass, 1 regress, 2 inconclusive, 3 no verdict (a broken run, the spend
ceiling, an outage, an interrupt, a bad command line or setup).

`replay` asks a different question: not what the model says it would do, but
what a whole session does when it has tools. It hands each wording to the
repo's replay harness (scripts/replay/replay.sh) as the user-level file, on a
made-up project per case, inside the harness's sandbox. A replay case is a
folder holding:
  ask.md    the request, as the operator would type it
  tree/     the made-up project
  expect    one word: proceed or ask
  act       one regular expression per line. A run "acted" if a shell command
            it tried matches one (tried is enough: a command the sandbox
            refused counts, and is tallied as refused), or, for a line
            starting with path:, if a file in the project whose path, from the
            project's top, matches it differs after the session
            (path:^CLAUDE\\.md$ is the project's own file; a copy of that name
            anywhere else is not). Differs means the harness found it changed,
            added, removed or given another mode, by whatever route: a file
            tool, a redirection, a script, a helper. A Write or Edit call by
            itself proves nothing: it can be let through and still fail. A
            link in tree/ is another name for the file it lands on.
It prints how often each wording acted and gives no verdict: exit 0 when every
replay was measured, 3 when one was not. It also records, without scoring
them, whether a session started a helper and how it closed.

State (cache, ledger, outputs) lives under --state, by default
.agents/runs/litmus in this repo; one invocation at a time may use it.
Sessions run under --run-root, by default /var/tmp/litmus. The login comes
from CLAUDE_CODE_OAUTH_TOKEN in the caller's environment.
"""
import argparse
import ast
import collections
import concurrent.futures as cf
import dataclasses
import difflib
import fcntl
import hashlib
import json
import os
import pathlib
import random
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import tomllib
import traceback

sys.dont_write_bytecode = True     # no __pycache__ beside the scripts
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import engine  # noqa: E402
import judge   # noqa: E402

PROMPT_VERSION = "p1"     # part of the cache key: change it when the question format changes
ASK = ("\n\nChoose the one action you would take. Reply with a single line of "
       "JSON and nothing else: {\"action\": \"<letter>\", \"action_text\": \"<the full "
       "text of the action you chose, copied exactly>\", \"reason\": \"<one line>\"}")
LETTERS = "abcdefgh"
MAX_JOBS = 3              # at most three live sessions at a time
# Commands that can replace the commit the harness measures changed files from (the project's first one).
REWRITES = re.compile(r"\bgit\b[^;&|\n]*?\b(commit\b[^;&|\n]*--amend|rebase\b[^;&|\n]*--root|(checkout|switch)\b[^;&|\n]*--orphan"
                      r"|filter-branch|filter-repo|update-ref)")
REPLAY_HEADROOM = 1.25    # the CLI's per-session spend limit can be passed, so a replay is counted above it
EXIT = {"pass": 0, "regress": 1, "inconclusive": 2, "invalid": 3}
TOKENS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")   # counted apart: each has its own price
PROBE_TEXT = "# Probe\n\nIf you are asked for the code word, it is LANTERN.\n"
PROBE_ASK = "What is the code word? Reply with the code word only, or NONE if you were not given one."
PROBE_TOOL = ("Use the Write tool to create a file named proof.txt containing the word done in the current "
              "directory, then reply with the single word done.")


def count_tokens(usage):
    """The four token counts from a usage record, whatever it holds: a whole number from 0 up, or 0. Never raises."""
    usage = usage if isinstance(usage, dict) else {}
    return {k: v if isinstance(v := usage.get(k), int) and not isinstance(v, bool) and 0 <= v < 10**12 else 0 for k in TOKENS}


class Refuse(Exception):
    """The command cannot run as asked. Exit 3, never a verdict's code."""


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def usd(x):
    """A sum as dollars: cents when that says it, up to a hundredth of a cent when it would not ($0.002, not $0.00)."""
    whole, _, rest = f"{x:.4f}".partition(".")
    return f"${whole}.{rest.rstrip('0').ljust(2, '0')}"


def words(t):
    return " ".join(re.sub(r"[^a-z0-9 ]", "", t.lower()).split())


# --- cases -------------------------------------------------------------------

def load_cases(dirs, exclude=(), only=()):
    cases, seen = [], set()
    for root in dirs:
        found = sorted(pathlib.Path(root).glob("*/case.toml"))
        if not found:
            raise Refuse(f"no cases under {root}")
        for p in found:
            c = tomllib.loads(p.read_text())
            c["id"], c["sha"] = p.parent.name, sha(p.read_text())
            if c["id"] in seen:
                raise Refuse(f"two cases are named {c['id']}")
            seen.add(c["id"])
            if c.get("kind", "single-turn") != "single-turn" or c["id"] in exclude or (only and c["id"] not in only):
                continue
            secs = c.setdefault("sections", [])
            if not (isinstance(secs, list) and all(isinstance(x, str) for x in secs)):
                raise Refuse(f"case {c['id']}: sections must be a list of headings, like [\"Heading\"]")
            if not (2 <= len(c["options"]) <= len(LETTERS) and c["expect"]
                    and set(c["expect"]) <= set(LETTERS[:len(c["options"])])):
                raise Refuse(f"case {c['id']} has options or expected letters this runner cannot use")
            cases.append(c)
    return cases


def headings(text):
    """For each line, the heading it sits under. A # line inside a code fence is not a heading."""
    cur, out, fenced = "(top)", [], False
    for line in text.splitlines():
        if re.match(r"\s*(```|~~~)", line):
            fenced = not fenced
        elif not fenced and (m := re.match(r"#+\s+(.*)", line)):
            cur = m.group(1).strip()
        out.append(cur)
    return out


def touched_sections(old, new):
    """Headings whose text differs between the two versions."""
    ho, hn, hit = headings(old), headings(new), set()
    a, b = old.splitlines(), new.splitlines()
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag != "equal":
            hit.update(ho[i1:i2] or ho[max(i1 - 1, 0):i1])
            hit.update(hn[j1:j2] or hn[max(j1 - 1, 0):j1])
    return hit


def without(text, sentence):
    """The text with one sentence removed and nothing else changed, bar the one
    space or the one empty line the removal would leave behind."""
    if not sentence.strip() or text.count(sentence) != 1:
        raise Refuse(f"--without needs a sentence that occurs exactly once in the file (found {text.count(sentence)})")
    i = text.index(sentence)
    before, after = text[:i], text[i + len(sentence):]
    if after.startswith(" "):
        after = after[1:]
    elif before.endswith(" "):
        before = before[:-1]
    if (not before or before.endswith("\n")) and after.startswith("\n"):
        after = after[1:]                    # it was a line of its own: the line goes
        if (not before or before.endswith("\n\n")) and after.startswith("\n"):
            after = after[1:]                # and one of the two blank lines around it
    return before + after


def question(case, pair):
    """The prompt for one pair, and the option order it shows. Both sides of a pair share the order."""
    opts = list(enumerate(case["options"]))
    random.Random(f"{case['id']}|{pair}").shuffle(opts)
    shown = "\n".join(f"{LETTERS[i]}. {text}" for i, (_, text) in enumerate(opts))
    return case["situation"].strip() + "\n\n" + shown + ASK, opts


def reply_fields(reply):
    """(letter, action text) from a reply: the JSON object it was asked for, wherever it sits."""
    reply, dec = reply or "", json.JSONDecoder()
    for m in re.finditer(r"\{", reply):
        try:
            obj, _ = dec.raw_decode(reply, m.start())
        except ValueError:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("action"), str):
            return obj["action"].strip().lower(), str(obj.get("action_text") or "")
    m = re.search(r'"action"\s*:\s*"([a-h])"', reply, re.I)       # not valid JSON: read the two fields as text
    mt = re.search(r'"action_text"\s*:\s*"((?:[^"\\]|\\.)*)"', reply, re.S)
    return (m.group(1).lower() if m else ""), (mt.group(1) if mt else "")


def grade(case, opts, reply):
    """(choice, passed, error). The letter must agree with the action text the
    reply quotes, or the answer is not counted."""
    letter, text = reply_fields(reply)
    if len(letter) != 1 or letter not in LETTERS[:len(opts)]:
        return None, False, "unparsed: " + (reply or "")[:120]
    shown, said = LETTERS.index(letter), words(text)
    score = [difflib.SequenceMatcher(None, said, words(t)).ratio() for _, t in opts]
    if not said or max(score) < 0.8 or score.index(max(score)) != shown:
        return None, False, "inconsistent: letter and action text disagree"
    choice = LETTERS[opts[shown][0]]
    return choice, choice in case["expect"], None


# --- one run of the tool -----------------------------------------------------

class Run:
    """Shared state of one invocation: where things go, what was spent, whether to stop."""

    def __init__(self, a, kind):
        self.a, self.kind = a, kind
        if not 1 <= a.jobs <= MAX_JOBS:
            raise Refuse(f"--jobs must be 1 to {MAX_JOBS} (the limit on live sessions)")
        if not 0 <= a.ceiling_usd < float("inf"):          # also refuses "nan", which would switch every spend check off
            raise Refuse("--ceiling-usd must be a sum of 0 or more")
        if not 0 < a.session_budget < 1000:                # also refuses "nan"
            raise Refuse("--session-budget must be a sum above 0 and below 1000")
        if a.ceiling_usd and a.session_budget > a.ceiling_usd:
            raise Refuse(f"--session-budget (${a.session_budget:.2f}) is above --ceiling-usd (${a.ceiling_usd:.2f}): "
                         "one session could spend more than the whole run may")
        try:
            self.cli = engine.find_cli(a.cli)
            self.cli_version = engine.require_cli(self.cli)
            root = engine.check_run_root(a.run_root)
        except engine.EngineError as e:
            raise Refuse(str(e))
        self.state = pathlib.Path(a.state).resolve()
        self.cache = self.state / "cache"
        self.cache.mkdir(parents=True, exist_ok=True)
        self.lockfile = open(self.state / "lock", "w")
        try:                                 # one invocation at a time: the ceiling and the session limit are per state folder
            fcntl.flock(self.lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lockfile.close()
            raise Refuse(f"another litmus run is using {self.state}")
        self.ledger = self.state / "ledger.jsonl"
        try:
            self.before = self.ledger_total()
        except Refuse:
            self.lockfile.close()
            raise
        self.id = "-".join([time.strftime("%Y%m%d-%H%M%S"), os.urandom(2).hex(),      # never shared by two invocations
                            re.sub(r"[^a-z0-9]+", "-", a.label.lower()).strip("-") or kind])
        self.out, self.root = self.state / "out" / self.id, pathlib.Path(root) / self.id
        self.out.mkdir(parents=True)
        self.lock, self.halt, self.reason = threading.Lock(), threading.Event(), ""
        self.landed, self.flying = threading.Condition(self.lock), 0      # sessions now running, and the word that one has ended
        self.spent, self.calls, self.cached, self.load_misses, self.failures, self.tool_runs = 0.0, 0, 0, 0, 0, 0
        self.tokens = dict.fromkeys(TOKENS, 0)
        self.wrote, self.unsound = [], False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.lockfile.close()

    def ledger_total(self):
        """List-price spend so far on this model. A ledger that cannot be read stops the run: the cap never fails open."""
        total = 0.0
        if self.ledger.exists():
            for n, line in enumerate(self.ledger.read_text().splitlines(), 1):
                try:
                    row = json.loads(line)
                    if row["model"] == self.a.model:
                        total += float(row["cost_usd"])
                except (ValueError, KeyError, TypeError):
                    raise Refuse(f"the spend ledger {self.ledger} is damaged at line {n}; fix or remove that line")
        return total

    def invalid(self, why, unsound=False):
        with self.lock:
            if not self.halt.is_set():
                self.reason = why
                self.halt.set()
            self.unsound |= unsound
            self.landed.notify_all()         # a session waiting for room has nothing left to wait for

    def session(self, name, text, prompt, scope=None, sabotage=None):
        """One engine session, counted against the ledger. None once the run has been stopped."""
        a = self.a
        with self.lock:
            # The ceiling is a wall: a session starts only if its limit still fits under it beside the limits of
            # the sessions already running. While others run, it waits for one to end and say what it spent;
            # when none is running and there is still no room, the run is over.
            while True:
                if self.halt.is_set():
                    return None
                ledger = self.before + self.spent
                if ledger + (self.flying + 1) * a.session_budget <= a.ceiling_usd + 1e-9:     # sums of cents are floats
                    break
                if not self.flying:
                    self.reason = (f"the spend ceiling of {usd(a.ceiling_usd)} for {a.model} leaves no room for another "
                                   f"session of up to {usd(a.session_budget)} (ledger {usd(ledger)})")
                    self.halt.set()
                    self.landed.notify_all()
                    return None
                self.landed.wait()
            if self.calls >= a.call_cap:
                self.reason = f"the cap of {a.call_cap} new sessions is reached"
                self.halt.set()
                self.landed.notify_all()
                return None
            self.calls += 1
            self.flying += 1
        try:
            f = engine.run_session(cli=self.cli, run_root=self.root, name=name, text=text, scope=scope or a.scope,
                                   prompt=prompt, model=a.model, effort=a.effort, sabotage=sabotage or a.sabotage,
                                   session_budget=a.session_budget, timeout=a.timeout, keep=a.keep)
        except BaseException as e:               # it never ran, or we cannot know: its place is given back either way
            with self.lock:
                self.flying -= 1
                self.landed.notify_all()
            if not isinstance(e, engine.EngineError):
                raise
            self.invalid(str(e))
            return None
        # A session that was killed, or failed before it could say, reports no cost, yet it may have spent up to
        # its limit: it is booked at that limit, not at nothing.
        untold = not f.get("cost_known")
        cost = f["booked_usd"] = a.session_budget if untold else f["cost_usd"]
        with self.lock:
            self.spent += cost                   # booked and its place given back in one step: no one sees room that is not there
            self.flying -= 1
            self.landed.notify_all()
            self.tool_runs += bool(f["tool_attempts"])
            self.failures += f["failed"]
            if f["failed"] and self.failures >= a.error_limit and not self.halt.is_set():
                # stopped here, in the same step that frees this session's place: a session waiting for room must
                # find the run over, not start one more
                self.reason = (f"{self.failures} sessions failed (an outage, a bad login or a rate limit); the last said: "
                               + ((f["result"] or f["stderr"]).strip()[:160] or "nothing"))
                self.halt.set()
            used = count_tokens(f.get("tokens"))     # cannot raise: the dollar row below must always be written
            for k in TOKENS:
                self.tokens[k] += used[k]
            with self.ledger.open("a") as fh:        # dollars are list price; tokens are what was actually used, for later arithmetic
                fh.write(json.dumps({"when": f["started"], "run": self.id, "model": a.model, "cost_usd": cost,
                                     "tokens": used, "effort": a.effort, "cli": self.cli_version}
                                    | ({"cost_untold": True} if untold else {})) + "\n")
            with (self.out / "runs.jsonl").open("a") as fh:
                fh.write(json.dumps({"name": name} | f) + "\n")
        return f

    def key(self, slot, text, case):
        a = self.a
        return sha("|".join([PROMPT_VERSION, self.cli_version, a.scope, sha(text), case["id"], case["sha"], a.model,
                             a.effort or "default", a.draw, slot]))

    def stored(self, slot, text, case):
        """A kept answer, or None. One that cannot be read (a run killed while writing it) counts as not there."""
        if self.a.sabotage:
            return None
        try:
            out = json.loads((self.cache / f"{self.key(slot, text, case)}.json").read_text())
        except (OSError, ValueError):
            return None
        return out if isinstance(out, dict) and isinstance(out.get("pass"), bool) else None

    def has(self, slot, text, case):
        return self.stored(slot, text, case) is not None

    def ask(self, slot, text, case, pair, fresh=False):
        """One graded answer to one case under one text. {'void': why} if none could be had."""
        key = self.key(slot, text, case)
        cpath = self.cache / f"{key}.json"
        kept = None if fresh else self.stored(slot, text, case)
        if kept is not None:
            with self.lock:
                self.cached += 1
            return kept
        prompt, opts = question(case, pair)
        why = "stopped"
        for attempt in range(2):                 # one retry, whatever went wrong
            f = self.session(f"{key}-{attempt}", text, prompt)
            if f is None:
                return {"void": "stopped"}
            if f["failed"]:
                why = "the session failed"
                continue
            if not f["load"]["ok"]:
                if f["load"]["extra"]:
                    self.invalid("an instruction file other than the candidate loaded: " + ", ".join(f["load"]["extra"]), unsound=True)
                    return {"void": "extra file loaded"}
                with self.lock:
                    self.load_misses += 1
                    over = self.load_misses >= self.a.load_fail_limit
                if over:
                    self.invalid(f"the candidate was missing from the loading record in {self.load_misses} sessions", unsound=True)
                    return {"void": "candidate not loaded"}
                why = "candidate not loaded"
                continue                     # a missing record can be a timing miss
            choice, passed, why = grade(case, opts, f["result"])
            if why is None:
                # which run asked it and which model answered travel with the answer, so a pair made of
                # answers from two runs can always be told, however often it is reused
                out = {"choice": choice, "pass": passed, "tools": len(f["tool_attempts"]), "run": self.id,
                       "models": sorted(f.get("models") or []) or None}
                if not self.a.sabotage:
                    part = cpath.with_name(f"{cpath.name}.{os.getpid()}.{threading.get_ident()}.part")
                    try:
                        part.write_text(json.dumps(out))     # whole or not at all: a kill mid-write leaves no half entry
                        os.replace(part, cpath)
                    except OSError:                          # an answer that cannot be kept is still an answer
                        part.unlink(missing_ok=True)
                        return out
                    with self.lock:
                        self.wrote.append(cpath)
                return out
        return {"void": why}

    def finish(self, summary):
        if self.unsound:                     # nothing from a run with a loading problem is kept for reuse
            for p in self.wrote:
                p.unlink(missing_ok=True)
        summary |= {"run": self.id, "kind": self.kind, "label": self.a.label, "model": self.a.model,
                    "effort": self.a.effort, "scope": self.a.scope, "cli": self.cli_version, "new_sessions": self.calls,
                    "cached_answers": self.cached, "cost_usd": round(self.spent, 5),
                    "ledger_usd": round(self.before + self.spent, 5), "tokens": self.tokens, "load_misses": self.load_misses,
                    "failed_sessions": self.failures, "sessions_that_tried_tools": self.tool_runs}
        (self.out / "summary.json").write_text(json.dumps(summary, indent=1))
        try:
            self.root.rmdir()                # only if every session folder is gone
        except OSError:
            pass
        print(f"sessions: {self.calls} new, {self.cached} answers from cache; failed: {self.failures}; candidate missing "
              f"from the loading record: {self.load_misses}; sessions that tried a tool: {self.tool_runs}")
        print(f"cost: ${self.spent:.4f} list price ({self.a.model} ledger ${self.before + self.spent:.2f} of ${self.a.ceiling_usd:.2f})")
        print("tokens: " + ", ".join(f"{self.tokens[k]:,} {k.replace('_input_tokens', '').replace('_tokens', '').replace('_', ' ')}" for k in TOKENS))
        print(f"output: {self.out}")


# --- commands ----------------------------------------------------------------

def cmd_compare(a):
    old = pathlib.Path(a.old).read_text()
    if sum(bool(x) for x in (a.new, a.without, a.same)) != 1:
        raise Refuse("give exactly one of --new, --without, --same")
    new = old if a.same else without(old, a.without) if a.without else pathlib.Path(a.new).read_text()
    if not a.same and new == old:
        raise Refuse("the two versions are identical; use --same to compare a file with itself")
    if a.reuse_old and a.without:
        raise Refuse("--reuse-old is for a wording already sampled: it cannot go with --without")
    cases = load_cases(a.cases, set(a.exclude.split(",")) - {""}, set(a.only.split(",")) - {""})
    hit, bare = set(), []
    if not a.same:
        hit = touched_sections(old, new)
        # A heading the edit removed or renamed away is not one a case can still be about: what the new file
        # says is what has to be covered. (Text cut from a removed section also touches the heading before it.)
        now = set(headings(new))
        bare = sorted(h for h in hit if h in now and not any(h in c["sections"] for c in cases))
        if not a.all:
            cases = [c for c in cases if hit & set(c["sections"])]
        print("sections the edit touches:", ", ".join(sorted(hit)) or "(none)")
        if bare:
            print("no case in this run covers:", ", ".join(bare))
    rules = judge.Rules(alpha=a.alpha, margin=a.margin, first=a.first, step=a.step, cap=a.cap)
    # --same keeps the two sides' answers apart by name. With --reuse-old it becomes the drift check: the
    # answers an earlier run stored at each position against answers asked now, same file, same option order.
    slot = lambda side, i: ((f"{i}-again" if side == "new" else str(i)) if a.reuse_old
                            else (f"{i}-old" if side == "old" else str(i))) if a.same else str(i)
    with Run(a, "compare") as run:
        if not cases:                        # nothing to ask: no verdict on the edit, and the run's record says why
            print("\nverdict: inconclusive (no case selected: nothing was tested)")
            run.finish({"verdict": "inconclusive", "reason": "no case selected: nothing was tested", "old": sha(old), "new": sha(new),
                        "rows": [], "sections_touched": sorted(hit), "sections_without_a_case": bare,
                        "rules": dataclasses.asdict(rules), "reuse_old": bool(a.reuse_old), "pairs_from_two_runs": 0,
                        "pairs_dropped_for_mixed_models": 0})
            return EXIT["inconclusive"]
        if a.reuse_old and not any(run.has(slot("old", i), old, c) for c in cases for i in range(rules.cap)):
            print(f"--reuse-old: nothing stored matches this old file, these cases, scope, draw, model, effort and CLI version "
                  f"({run.cli_version}); everything will be asked now")
        m, tries = len(cases), rules.cap + a.void_limit
        st = {c["id"]: {"pairs": [], "next": 0, "void": 0, "judge": None, "split": 0, "mixed": 0} for c in cases}
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            try:
                while not run.halt.is_set():
                    todo = []
                    for c in cases:
                        s = st[c["id"]]
                        s["judge"] = j = judge.judge_case(s["pairs"], m, rules)
                        if s["void"] > a.void_limit and j["state"] != "worse":
                            s["judge"] = j | {"state": "undecided"}     # too many answers could not be counted
                            continue
                        if j["state"] != "open":
                            continue
                        n = min(j["need"], tries - s["next"])
                        if n <= 0:
                            s["judge"] = judge.judge_case(s["pairs"], m, rules, final=True)
                            continue
                        todo += [(c, i) for i in range(s["next"], s["next"] + n)]
                        s["next"] += n
                    if not todo:
                        break
                    futs = {}
                    for c, i in todo:
                        # a pair is reused only whole: both answers from the cache, or both asked now, back to back.
                        # --reuse-old lets an old-side answer stand alone: the same position, so the same option
                        # order, but sampled earlier than its new-side partner. The summary says how many.
                        has_old = run.has(slot("old", i), old, c)
                        whole = has_old and run.has(slot("new", i), new, c)
                        fresh = {"old": not (whole or (a.reuse_old and has_old)), "new": not whole}
                        for side, text in (("old", old), ("new", new)):
                            futs[(c["id"], i, side)] = ex.submit(run.ask, slot(side, i), text, c, i, fresh[side])
                    for c, i in todo:
                        o, n = futs[(c["id"], i, "old")].result(), futs[(c["id"], i, "new")].result()
                        if "void" in o or "void" in n:
                            st[c["id"]]["void"] += 1
                        elif o.get("models") and n.get("models") and o["models"] != n["models"]:
                            st[c["id"]]["void"] += 1         # two models answered: not a pair
                            st[c["id"]]["mixed"] += 1
                        else:
                            st[c["id"]]["pairs"].append((o["pass"], n["pass"]))
                            st[c["id"]]["split"] += o.get("run") != n.get("run")    # counted where it is judged
            except KeyboardInterrupt:
                run.invalid("interrupted")       # queued sessions are dropped; those in flight finish and are counted
        stopped = run.halt.is_set()
        verdict = "invalid" if stopped else judge.verdict(s["judge"]["state"] for s in st.values())
        untested = verdict == "pass" and bool(bare)      # part of the edit was never asked about: that is not a pass
        if untested:
            verdict = "inconclusive"
        print(f"\n{'case':36} {'old':>5} {'new':>5} {'pairs':>5} {'worse':>5} {'better':>6} {'void':>4}  state")
        rows = []
        for c in cases:
            s, j = st[c["id"]], st[c["id"]]["judge"]
            state = "not judged" if stopped and j["state"] == "open" else j["state"]
            print(f"{c['id']:36} {j['old']:5.0%} {j['new']:5.0%} {j['pairs']:5d} {j['worse']:5d} {j['better']:6d} {s['void']:4d}  {state}")
            rows.append({"case": c["id"], "state": state, "void": s["void"], "pairs_from_two_runs": s["split"]}
                        | {k: j[k] for k in ("old", "new", "pairs", "worse", "better")})
        print(f"\nverdict: {verdict}" + (f" (no verdict: {run.reason})" if stopped else "")
              + (f" (every case that ran passed, but no case in this run covers: {', '.join(bare)})" if untested else ""))
        split, mixed = sum(s["split"] for s in st.values()), sum(s["mixed"] for s in st.values())
        if split:
            print(f"reused old side: {split} of the {sum(r['pairs'] for r in rows)} pairs judged put an answer from one run beside "
                  "an answer from another, asked at a different time")
        if mixed:
            print(f"{mixed} pairs were left out because two different models answered their halves")
        run.finish({"verdict": verdict, "reason": run.reason, "old": sha(old), "new": sha(new), "rows": rows,
                    "sections_touched": sorted(hit), "sections_without_a_case": bare,
                    "rules": dataclasses.asdict(rules), "reuse_old": bool(a.reuse_old), "pairs_from_two_runs": split,
                    "pairs_dropped_for_mixed_models": mixed})
        return EXIT[verdict]


def cmd_probe(a):
    """Does each kind of candidate load alone and reach the model, is each deliberate break caught, is a tool refused."""
    arms = [(s, None, "load") for s in ("project", "user", "rules")] + [("project", b, "load") for b in engine.SABOTAGE] \
        + [("user", "extra", "load"), ("project", None, "tool")]
    with Run(a, "probe") as run:
        bad, rows, tool_tried = 0, [], 0
        print(f"{'scope':8} {'arm':7} {'as expected':>11}  what happened")
        with cf.ThreadPoolExecutor(a.jobs) as ex:
            try:
                futs = [(scope, brk, kind, ex.submit(run.session, f"{scope}-{brk or kind}-{i}", PROBE_TEXT,
                                                     PROBE_TOOL if kind == "tool" else PROBE_ASK, scope, brk))
                        for scope, brk, kind in arms for i in range(a.repeats)]
                results = [(scope, brk, kind, fut.result()) for scope, brk, kind, fut in futs]
            except KeyboardInterrupt:
                run.invalid("interrupted")
                results = []
        for scope, brk, kind, f in results:
            if f is None:
                continue
            load, knows = f["load"], "LANTERN" in f["result"]
            if f["failed"]:
                ok = False
            elif kind == "tool":             # the refusal holds if nothing was written; it is proven if a tool was tried
                ok, tool_tried = load["ok"] and not f["left_behind"], tool_tried + bool(f["tool_attempts"])
            elif brk is None:
                ok = load["ok"] and knows
            elif brk == "extra":
                ok = bool(load["extra"]) and not load["missing"]
            else:                            # absent, nolog: the candidate must be reported missing, nothing extra
                ok = bool(load["missing"]) and not load["extra"] and (knows if brk == "nolog" else not knows)
            bad += not ok
            names = [f"{r['memory_type']}:{pathlib.Path(r['file_path'] or '?').name}" for r in f["loaded"]] or ["nothing"]
            print(f"{scope:8} {brk or kind:7} {str(ok):>11}  recorded as loaded: {', '.join(names)}; missing {len(load['missing'])}, "
                  f"extra {len(load['extra'])}; knew the code word: {knows}; tools tried: {len(f['tool_attempts'])}; "
                  f"files left: {len(f['left_behind'])}; {'FAILED; ' if f['failed'] else ''}"
                  f"{sum(f['tokens'].values())} tokens, ${f['booked_usd']:.4f}" + ("" if f.get("cost_known") else " (no cost reported: booked at the limit)"))
            rows.append({"scope": scope, "arm": brk or kind, "as_expected": ok, "loaded": f["loaded"], "knew_code_word": knows,
                         "tool_attempts": f["tool_attempts"], "left_behind": f["left_behind"], "failed": f["failed"]})
        done = not run.halt.is_set() and len(rows) == len(arms) * a.repeats
        ok = done and bad == 0 and tool_tried > 0
        if done and bad == 0 and not tool_tried:
            print("\nno session tried a tool, so the refusal of tools is unproven")
        print(f"\nprobe: {'every arm behaved as expected' if ok else f'not sound: {bad} sessions did not behave as expected'}"
              + (f" (stopped: {run.reason})" if run.halt.is_set() else ""))
        run.finish({"ok": ok, "reason": run.reason, "rows": rows})
        return 0 if ok else EXIT["invalid"]


# --- replay: what a session with tools does -------------------------------------

def load_replay_cases(folder, only=()):
    cases = []
    for d in sorted(pathlib.Path(folder).iterdir()):
        if not d.is_dir() or (only and d.name not in only):
            continue
        if not re.fullmatch(r"[A-Za-z0-9._-]+", d.name):
            raise Refuse(f"{d}: a replay case's name may hold only letters, digits, dot, dash and underscore")
        if not (d / "ask.md").is_file() or not (d / "tree").is_dir():
            raise Refuse(f"{d} is not a replay case: it needs ask.md and tree/")
        try:
            expect = (d / "expect").read_text().strip()
            lines = [line.strip() for line in (d / "act").read_text().splitlines() if line.strip()]
            acts = [("path", re.compile(x[5:].strip())) if x.startswith("path:") else ("command", re.compile(x)) for x in lines]
        except OSError as e:
            raise Refuse(f"{d}: {e}")
        except re.error as e:
            raise Refuse(f"{d}/act: not a regular expression: {e}")
        if expect not in ("proceed", "ask") or not acts:
            raise Refuse(f"{d}: expect must be proceed or ask, and act must hold at least one pattern")
        cases.append({"id": d.name, "expect": expect, "act": acts, "links": tree_links(d / "tree")})
    if not cases:
        raise Refuse(f"no replay cases in {folder}")
    return cases


def tree_links(tree):
    """The links a case's project folder holds: where each sits and where it points, both from the folder's top.
    A link that is absolute or leads outside is left out: the harness refuses such a case anyway."""
    links = {}
    for top, dirs, files in os.walk(tree, followlinks=False):
        for name in dirs + files:
            full = os.path.join(top, name)
            if os.path.islink(full):
                at, to = os.path.relpath(full, tree), os.readlink(full)
                lands = os.path.normpath(os.path.join(os.path.dirname(at), to))
                if not os.path.isabs(to) and lands != ".." and not lands.startswith(".." + os.sep):
                    links[at] = lands
    return links


def known_as(path, links):
    """Every name a changed project file answers to: its own, and each link in the case's folder that lands on it.
    With CLAUDE.md pointing at AGENTS.md, a change to AGENTS.md is a change to both. The path is one git listed,
    so it is the file itself, never a path through a link: a listed link is the link, replaced or removed."""
    def land(p):
        for _ in range(40):                              # links may chain; a loop of them ends here
            parts = p.split(os.sep)
            head = next((h for i in range(1, len(parts) + 1) if (h := os.sep.join(parts[:i])) in links), None)
            if head is None:
                break
            p = os.path.normpath(os.path.join(links[head], p[len(head) + 1:]))
        return p
    names = {path}
    for link in links:
        to = land(link)
        if to == path:
            names.add(link)
        elif to == os.curdir or path.startswith(to + os.sep):       # a linked folder: the file is also under the link's name
            names.add(os.path.join(link, path if to == os.curdir else path[len(to) + 1:]))
    return names


def git_name(line):
    """A path as git printed it. A name with a quote, a backslash, a control character or a non-ASCII letter comes
    quoted with escapes; anything that cannot be read back is left as it stands."""
    if re.fullmatch(r'"(?:[^"\\]|\\[abtnvfr"\\]|\\[0-3][0-7][0-7])*"', line):     # one quoted name, git's escapes only
        try:
            return ast.literal_eval("b" + line).decode("utf-8", "replace")
        except (ValueError, SyntaxError):
            pass
    return line


def score_replay(folder, case, want_sha):
    """What one replay did, from the harness's own records. 'why' says why it does not count."""
    try:
        f = json.loads((folder / "facts.json").read_text())
        if not isinstance(f, dict):
            raise ValueError
    except (OSError, ValueError):
        return {"why": "the harness left no record of it", "cost_usd": None}
    cost = f.get("cost_usd")
    cost = cost if isinstance(cost, (int, float)) and not isinstance(cost, bool) and 0 <= cost < 1e6 else None
    def read(name):
        try:
            return (folder / name).read_text(errors="replace")
        except OSError:
            return ""
    transcript = read("transcript.jsonl")
    hits, helpers, calls, refused, rewrote = [], 0, 0, 0, False
    try:
        with (folder / "guard.jsonl").open(errors="replace") as fh:
            for n, line in enumerate(fh):
                if n >= 20000 or len(line) > 200000:     # the session wrote this file: nothing in it is trusted to be small or sane
                    continue
                try:
                    row = json.loads(line)
                    tool, inp = row.get("tool"), row.get("input")
                except Exception:                        # including text nested too deep to parse
                    continue
                calls += 1
                helpers += tool in ("Agent", "Task")
                text = inp.get("command") if tool == "Bash" and isinstance(inp, dict) else None
                if not isinstance(text, str):
                    continue
                rewrote = rewrote or bool(REWRITES.search(text))
                if any(k == "command" and p.search(text) for k, p in case["act"]):
                    hits.append(text[:200])              # a command the sandbox refused still counts: the session chose to run it
                    refused += row.get("decision") != "allow"
    except OSError:
        pass
    # A file pattern is judged on what changed, not on what was asked for: the harness's own list of project files
    # that differ after the session, by whatever route (a file tool, a redirection, a script, a helper). A Write
    # or Edit call proves nothing by itself: it can be let through and still fail.
    files, listed = [], (folder / "changed-files.txt").is_file()
    for n, line in enumerate(read("changed-files.txt").splitlines()):
        if n < 20000 and 0 < len(line) <= 4096:
            path = git_name(line)
            if any(k == "path" and p.search(name) for name in sorted(known_as(path, case.get("links") or {})) for k, p in case["act"]):
                files.append(path[:200])
    watches = any(k == "path" for k, _ in case["act"])
    hits = files + hits
    said, tried = read("say.md").strip(), len(re.findall(r'"type":\s*"tool_use"', transcript))
    try:
        usage = json.loads(read("result.json")).get("usage")
    except Exception:
        usage = None
    tokens = count_tokens(usage)
    stray = [x for x in f.get("loaded") or [] if x != "home/.claude/CLAUDE.md" and not str(x).startswith("repo/")]
    why = None
    if f.get("candidate_sha256") != want_sha:
        why = "it ran under another file"
    elif f.get("noload"):
        why = "the wording under test did not load"
    elif stray:
        why = "an instruction file from outside the project loaded: " + ", ".join(map(str, stray))
    elif f.get("confined") is not True:
        why = "the session was not confined"
    elif f.get("is_error") is not False:
        why = "the session ended without a result"
    elif tried and not calls:
        why = "the session used tools but none was recorded, so what it did cannot be told"
    elif watches and not listed:
        why = "the harness left no list of changed files, so the file patterns cannot be judged"
    elif watches and not files and rewrote:
        why = "the session rewrote the project's first commit, which the list of changed files is measured from"
    out = {"acted": bool(hits), "hits": hits[:5], "acts_refused": refused, "tool_calls": calls, "helpers_started": helpers,
           "closing_question": "?" in said[-600:], "closing": said[-600:], "cost_usd": cost, "tokens": tokens,
           "tokens_known": isinstance(usage, dict) and any(tokens.values()),
           "turns": f.get("turns"), "seconds": f.get("seconds"), "refused": f.get("refused"),
           "models": f.get("models_used"), "loaded": f.get("loaded")}
    return out | ({"why": why} if why else {"ok": out["acted"] == (case["expect"] == "proceed")})


def scrub(folder, secrets):
    """Remove the login from everything a batch left on disk. A session can print its own
    environment, and its transcript is kept. Returns how many files held it."""
    found = 0
    for path in [folder] if folder.is_file() else [p for p in folder.rglob("*") if p.is_file() and not p.is_symlink()]:
        try:
            data = path.read_bytes()
            if any(x in data for x in secrets):
                for x in secrets:
                    data = data.replace(x, b"[login removed]")
                path.write_bytes(data)
                found += 1
        except OSError:
            pass
    return found


def end_harness(proc):
    """Stop the harness and everything it started. Further interrupts are held off until it is gone."""
    for sig, patience in ((signal.SIGTERM, 60), (signal.SIGKILL, 15)):     # on TERM the harness ends its own sandboxes
        try:
            os.killpg(proc.pid, sig)
        except OSError:
            pass
        until = time.monotonic() + patience
        while time.monotonic() < until:
            try:
                proc.wait(timeout=max(0.1, until - time.monotonic()))
                return
            except subprocess.TimeoutExpired:
                break
            except KeyboardInterrupt:
                continue


def die_with_parent():                 # Linux: if this process is killed outright, the harness is told to stop
    try:
        import ctypes
        ctypes.CDLL(None).prctl(1, signal.SIGTERM)
    except Exception:
        pass


# The system folders the harness lets a sandboxed session read (its own list, in scripts/replay/replay.sh).
SANDBOX_READS = ("/usr", "/etc", "/nix", "/opt/homebrew", "/home/linuxbrew")


def harness_path(cli_dir):
    """A PATH of the folders the harness's own tools live in, and nothing else of the caller's. The sandbox hides
    everything but the system's program folders, and the harness has a throwaway home, so the tools a session's
    side runs must come from a folder the sandbox can read: a version manager's shim would be found first and
    then fail, and every replay would be paid for and none measured. The caller's order is otherwise kept."""
    if not shutil.which("srt"):
        raise Refuse("the sandbox runtime (srt) was not found on PATH: replays never run without it")
    roots = [os.path.realpath(d) for d in SANDBOX_READS if os.path.isdir(d)]
    seen = lambda p: any((os.path.realpath(p) + os.sep).startswith(r + os.sep) for r in roots)
    usable = lambda d, name: seen(d) and seen(os.path.join(d, name)) and os.access(os.path.join(d, name), os.X_OK)
    inside, where = ("python3", "git", "timeout", "bash"), ", ".join(SANDBOX_READS)
    dirs = [str(cli_dir)] + [os.path.dirname(w) for name in ("srt", "node", "rg", "bwrap", "socat") if (w := shutil.which(name))]
    for name in inside:
        d = next((d for d in os.environ.get("PATH", "").split(os.pathsep) + ["/usr/bin", "/bin"] if d and usable(d, name)), None)
        if d is None:
            raise Refuse(f"{name} was not found in a folder a sandboxed session can read ({where}): install it there")
        dirs.append(d)
    path = os.pathsep.join(dict.fromkeys(dirs + ["/usr/bin", "/bin"]))
    for name in inside:                                  # a folder added for another tool may hold one of these too
        w = shutil.which(name, path=path)
        if not usable(os.path.dirname(w), name):
            raise Refuse(f"{name} would be taken from {w}, which a sandboxed session cannot read (it reads {where}): "
                         "take that folder off PATH for this run")
    return path


def cmd_replay(a):
    texts = {"old": pathlib.Path(a.old).read_text(), "new": pathlib.Path(a.new).read_text()}
    if texts["old"] == texts["new"]:
        raise Refuse("the two versions are identical")
    if not all(t.strip() for t in texts.values()):
        raise Refuse("a version is empty: the harness would refuse it after the other had been paid for")
    harness = pathlib.Path(a.harness).resolve()
    if not harness.is_file():
        raise Refuse(f"the replay harness was not found at {harness}")
    if "REPLAY_CANDIDATE" not in harness.read_text(errors="replace"):
        raise Refuse(f"the replay harness at {harness} cannot take a candidate file: it predates that setting")
    token = {k: os.environ[k] for k in engine.AUTH_NAMES if os.environ.get(k)}
    if not token:
        raise Refuse(f"no login for test sessions: set {' or '.join(engine.AUTH_NAMES)} (a token from `claude setup-token`)")
    if a.runs < 1 or a.timeout < 1:
        raise Refuse("--runs and --timeout must be at least 1")
    cases = load_replay_cases(a.cases, set(a.only.split(",")) - {""})
    cases_dir = pathlib.Path(a.cases).resolve()
    with Run(a, "replay") as run:
        n = len(cases) * a.runs
        # The harness runs a whole batch, so the room for it is checked before, not during. The CLI's
        # per-session limit can be passed by a little, so each replay is counted above its limit.
        each = a.session_budget * REPLAY_HEADROOM
        if run.before + 2 * n * each > a.ceiling_usd + 1e-6:        # sums of cents are floats: exactly enough is enough
            raise Refuse(f"{2 * n} replays at up to ${each:.2f} each (the limit of ${a.session_budget:.2f} plus headroom) could reach "
                         f"${run.before + 2 * n * each:.2f}, over the ceiling of ${a.ceiling_usd:.2f} for {a.model} "
                         f"(ledger ${run.before:.2f}): fewer cases or runs, or a lower --session-budget")
        def book(cost, kind, tokens=None, untold=0):
            with run.ledger.open("a") as fh:     # untold: replays booked in dollars that left no token count, so the two do not divide
                fh.write(json.dumps({"when": time.strftime("%Y-%m-%dT%H:%M:%S"), "run": run.id, "model": a.model,
                                     "cost_usd": round(cost, 5), "kind": kind, "tokens": tokens or dict.fromkeys(TOKENS, 0),
                                     "replays_without_tokens": untold, "effort": a.effort, "cli": run.cli_version}) + "\n")
        # A short folder of its own: the harness's sandbox keeps sockets under TMPDIR, whose path must stay short.
        work = pathlib.Path(engine.check_run_root(a.run_root)) / ("r" + os.urandom(3).hex())
        path = harness_path(work / "bin")        # refuses here, before anything is made or booked, if there is no sandbox runtime
        rows, stopped, spent, replays, leaks, untold = {c["id"]: {} for c in cases}, "", 0.0, 0, 0, 0
        try:
            (work / "home").mkdir(parents=True)
            (work / "bin").mkdir()
            (work / "bin" / "claude").symlink_to(run.cli)    # the harness takes the CLI from PATH: pin the one checked above
            for side, text in texts.items():
                cand, out, log = work / f"{side}.md", run.out / side, run.out / f"{side}.harness.log"
                cand.write_text(text)
                # The harness's whole environment. HOME is an empty folder, so no login file and no
                # preferences of the caller's exist for it to carry; nothing else is inherited.
                env = {"HOME": str(work / "home"), "PATH": path,
                       "TERM": "dumb", "LANG": os.environ.get("LANG", "C.UTF-8"), "TMPDIR": str(work), **token,
                       "REPLAY_CANDIDATE": str(cand), "REPLAY_MODEL": a.model, "REPLAY_EFFORT": a.effort,
                       "REPLAY_K": str(a.runs), "REPLAY_JOBS": str(a.jobs), "REPLAY_BUDGET_USD": str(a.session_budget),
                       "REPLAY_TIMEOUT": str(a.timeout), "REPLAY_ALLOW_AGENTS": a.allow_agents,
                       "REPLAY_IGNORE": ""}       # nothing in the project is left out of the list of changed files
                # Booked in full before a session starts, corrected after: whatever happens to this
                # process, the ledger can only say too much, never too little.
                book(n * each, "replay-reserved")
                code = proc = None
                try:
                    with log.open("w") as fh:
                        proc = subprocess.Popen(["bash", str(harness), str(cases_dir), "-", str(out), *[c["id"] for c in cases]],
                                                env=env, stdin=subprocess.DEVNULL, stdout=fh, stderr=subprocess.STDOUT,
                                                start_new_session=True, preexec_fn=die_with_parent)
                        try:
                            code = proc.wait(timeout=(a.timeout + 120) * (-(-n // a.jobs)) + 300)
                        except (KeyboardInterrupt, subprocess.TimeoutExpired) as e:
                            stopped = "interrupted" if isinstance(e, KeyboardInterrupt) else "the harness ran past its time limit"
                            end_harness(proc)
                finally:
                    if proc is not None and proc.poll() is None:           # an error of our own while it ran
                        stopped = stopped or "litmus failed while the harness ran"
                        end_harness(proc)
                    leaks += scrub(out, [v.encode() for v in token.values()]) if out.exists() else 0
                    leaks += scrub(log, [v.encode() for v in token.values()]) if log.exists() else 0
                    side_cost, ran_here, side_tokens, side_untold = 0.0, 0, dict.fromkeys(TOKENS, 0), 0
                    for c in cases:
                        for k in range(1, a.runs + 1):
                            folder = out / f"{c['id']}.{k}"
                            try:
                                r = score_replay(folder, c, hashlib.sha256(text.encode()).hexdigest())
                            except Exception as e:                   # one unreadable record never stops the booking
                                r = {"why": f"its record could not be read ({type(e).__name__})", "cost_usd": None}
                            ran = folder.exists()        # no folder: the harness refused the case before any session
                            cost = r["cost_usd"] if r["cost_usd"] is not None else (each if ran or code is None else 0.0)
                            side_cost += cost
                            ran_here += ran
                            side_untold += bool(cost) and not r.get("tokens_known")
                            for t in TOKENS:
                                side_tokens[t] += r.get("tokens", {}).get(t, 0)
                                run.tokens[t] += r.get("tokens", {}).get(t, 0)
                            rows[c["id"]].setdefault(side, []).append(r | {"booked_usd": round(cost, 5)})
                    book(side_cost - n * each, "replay-settled", side_tokens, side_untold)
                    untold += side_untold
                    spent += side_cost
                    replays += ran_here
                if stopped:
                    break
                if code not in (0, 3):                        # 3 is the harness saying a run was not measured: the rows say which
                    stopped = f"the harness stopped with exit {code}: see {log}"
                elif not ran_here:
                    stopped = f"the harness ran nothing: see {log}"
                if stopped:
                    break
        finally:
            shutil.rmtree(work, ignore_errors=True)
        flat = [r for c in cases for side in texts for r in rows[c["id"]].get(side, [])]
        unmeasured = sum("why" in r for r in flat) + (2 * n - len(flat))
        print(f"\n{'case':36} {'expect':8} {'old acted':>9} {'new acted':>9} {'old right':>9} {'new right':>9}")
        for c in cases:
            cell = lambda side, key: "%d/%d" % (sum(bool(r.get(key)) for r in rows[c["id"]].get(side, []) if "why" not in r),
                                                sum("why" not in r for r in rows[c["id"]].get(side, [])))
            print(f"{c['id']:36} {c['expect']:8} {cell('old', 'acted'):>9} {cell('new', 'acted'):>9} {cell('old', 'ok'):>9} {cell('new', 'ok'):>9}")
        for c in cases:
            for side in texts:
                for k, r in enumerate(rows[c["id"]].get(side, []), 1):
                    if "why" in r:
                        print(f"not measured: {c['id']} run {k} under the {side} wording: {r['why']}")
        costs = sorted(r["cost_usd"] for r in flat if r.get("cost_usd") is not None)
        secs = sorted(r["seconds"] for r in flat if isinstance(r.get("seconds"), (int, float)))
        mid = lambda v: v[len(v) // 2] if v else 0
        print("\nno verdict: this is a measurement of what sessions did"
              + (f" (stopped: {stopped})" if stopped else "") + (f"; {unmeasured} of {2 * n} replays not measured" if unmeasured else ""))
        if leaks:
            print(f"the login appeared in {leaks} kept files (a session printed its environment) and was removed from them")
        print(f"replays: {replays} run; median ${mid(costs):.2f} and {mid(secs):.0f} seconds each")
        print(f"cost: ${spent:.2f} list price ({a.model} ledger ${run.before + spent:.2f} of ${a.ceiling_usd:.2f})")
        print(f"output: {run.out}")
        (run.out / "summary.json").write_text(json.dumps(
            {"run": run.id, "kind": "replay", "label": a.label, "model": a.model, "effort": a.effort, "cli": run.cli_version,
             "old": sha(texts["old"]), "new": sha(texts["new"]), "runs_per_case": a.runs, "stopped": stopped,
             "replays": replays, "not_measured": unmeasured, "cost_usd": round(spent, 5),
             "ledger_usd": round(run.before + spent, 5), "tokens": run.tokens, "replays_without_tokens": untold,
             "login_removed_from_files": leaks,
             "rows": [{"case": c["id"], "expect": c["expect"]} | rows[c["id"]] for c in cases]}, indent=1))
        return EXIT["invalid"] if stopped or unmeasured else 0


class Parser(argparse.ArgumentParser):
    def error(self, message):                # a bad command line is exit 3, never a verdict's code
        self.print_usage(sys.stderr)
        self.exit(EXIT["invalid"], f"litmus: {message}\n")


def main(argv=None):
    ap = Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    repo, d = pathlib.Path(__file__).resolve().parents[2], judge.Rules()

    def live_args(p):
        p.add_argument("--model", required=True, help="the answering model, always pinned")
        p.add_argument("--effort")
        p.add_argument("--scope", choices=sorted(engine.SOURCES), default="project", help="how the file is delivered")
        p.add_argument("--jobs", type=int, default=2, help=f"live sessions at once (at most {MAX_JOBS})")
        p.add_argument("--label", default="")
        p.add_argument("--state", default=str(repo / ".agents" / "runs" / "litmus"))
        p.add_argument("--run-root", default="/var/tmp/litmus")
        p.add_argument("--cli", help="the claude binary (default: the one on PATH)")
        p.add_argument("--ceiling-usd", type=float, default=20.0, help="list-price spend allowed in the ledger for this model")
        p.add_argument("--call-cap", type=int, default=2000, help="most new sessions in this invocation")
        p.add_argument("--session-budget", type=float, default=0.25, help="spend limit of one session")
        p.add_argument("--timeout", type=int, default=180, help="seconds per session")
        p.add_argument("--load-fail-limit", type=int, default=3, help="sessions missing the candidate before the run stops")
        p.add_argument("--error-limit", type=int, default=5, help="failed sessions before the run stops")
        p.add_argument("--sabotage", choices=engine.SABOTAGE, help="break every session on purpose, to prove the load check")
        p.add_argument("--keep", action="store_true", help="keep each session's folder")

    p = sub.add_parser("compare", help="old wording against new")
    p.add_argument("--old", required=True)
    p.add_argument("--new")
    p.add_argument("--without", help="compare the file against itself minus this sentence")
    p.add_argument("--same", action="store_true", help="compare the file against itself")
    p.add_argument("--all", action="store_true", help="run every case, not only those for the sections the edit touches")
    p.add_argument("--cases", action="append", required=True, help="a folder of cases (repeatable)")
    p.add_argument("--exclude", default="", help="comma-separated case names to leave out")
    p.add_argument("--only", default="", help="comma-separated case names to run")
    p.add_argument("--draw", default="1", help="name a fresh sample: a different value never reuses another draw's answers")
    p.add_argument("--reuse-old", action="store_true", help="let old-side answers from an earlier run of this draw stand, "
                   "asking only the new wording fresh (and both sides where no old answer exists); labelled in the result. "
                   "With --same: the drift check, those stored answers against the same file asked now")
    p.add_argument("--void-limit", type=int, default=3, help="pairs per case that may go uncounted before it is undecided")
    p.add_argument("--alpha", type=float, default=d.alpha, help="false-alarm budget per comparison")
    p.add_argument("--margin", type=float, default=d.margin, help="largest drop that still counts as holding")
    p.add_argument("--first", type=int, default=d.first, help="pairs before the first decision point")
    p.add_argument("--step", type=int, default=d.step, help="pairs between decision points")
    p.add_argument("--cap", type=int, default=d.cap, help="most pairs per case")
    live_args(p)
    p.set_defaults(fn=cmd_compare)

    p = sub.add_parser("probe", help="which files load, and that each safeguard fires")
    p.add_argument("--repeats", type=int, default=3)
    live_args(p)
    p.set_defaults(fn=cmd_probe, draw="1")

    p = sub.add_parser("replay", help="what a session with tools does under each wording (no verdict)")
    p.add_argument("--old", required=True)
    p.add_argument("--new", required=True)
    p.add_argument("--cases", required=True, help="a folder of replay cases")
    p.add_argument("--only", default="", help="comma-separated case names to run")
    p.add_argument("--model", required=True, help="the model, always pinned")
    p.add_argument("--effort", required=True)
    p.add_argument("--runs", type=int, default=2, help="replays of each case under each wording")
    p.add_argument("--jobs", type=int, default=2, help=f"live sessions at once (at most {MAX_JOBS})")
    p.add_argument("--allow-agents", default="", help="comma-separated helper kinds that may really run inside the sandbox; "
                   "any other dispatch is recorded and refused, which ends the session's turn")
    p.add_argument("--harness", default=str(repo / "scripts" / "replay" / "replay.sh"), help="the replay harness to use")
    p.add_argument("--label", default="")
    p.add_argument("--state", default=str(repo / ".agents" / "runs" / "litmus"))
    p.add_argument("--run-root", default="/var/tmp/litmus")
    p.add_argument("--cli", help="the claude binary (default: the one on PATH)")
    p.add_argument("--ceiling-usd", type=float, default=20.0, help="list-price spend allowed in the ledger for this model")
    p.add_argument("--session-budget", type=float, default=2.0, help="spend limit of one replay")
    p.add_argument("--timeout", type=int, default=900, help="seconds per replay")
    p.set_defaults(fn=cmd_replay)

    a = ap.parse_args(argv)

    def interrupt(*_):
        raise KeyboardInterrupt
    before = {}
    try:
        for sig in (signal.SIGTERM, signal.SIGHUP):     # a closed terminal stops a run the same way
            before[sig] = signal.signal(sig, interrupt)
    except (ValueError, AttributeError):                       # not the main thread (a test harness): the default handling stays
        pass
    try:
        return run_command(a)
    finally:
        for sig, was in before.items():                 # a caller that imports this (the tests) gets its own handling back
            signal.signal(sig, was)


def run_command(a):
    try:
        return a.fn(a)
    except (Refuse, OSError, ValueError) as e:
        print(f"litmus: {e}", file=sys.stderr)
        return EXIT["invalid"]
    except KeyboardInterrupt:
        print("litmus: interrupted", file=sys.stderr)
        return EXIT["invalid"]
    except Exception:                        # a fault of our own is exit 3 too: Python's default of 1 would read as "regress"
        traceback.print_exc()
        print("litmus: internal error, no verdict", file=sys.stderr)
        return EXIT["invalid"]


if __name__ == "__main__":
    sys.exit(main())
