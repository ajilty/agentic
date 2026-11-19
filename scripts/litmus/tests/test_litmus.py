"""Litmus without a model: the judge's arithmetic, and the engine and the
comparison command end to end against a stand-in for the claude CLI."""
import atexit
import contextlib
import fcntl
import io
import json
import os
import pathlib
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE.parent))
import engine  # noqa: E402
import judge   # noqa: E402
import litmus  # noqa: E402

R = judge.Rules()


def simulate(old, new, n_cases, draws, seed, rules=R):
    """Share of simulated cases ending in each state, judged as a live run would."""
    rng, out = random.Random(seed), {}
    for _ in range(draws):
        pairs = [(rng.random() < old, rng.random() < new) for _ in range(rules.cap)]
        s = judge.judge_case(pairs, n_cases, rules)["state"]
        out[s] = out.get(s, 0) + 1 / draws
    return out


class Judge(unittest.TestCase):
    def test_false_alarm_is_within_budget_exactly(self):
        for rules in (R, judge.Rules(first=30, cap=30), judge.Rules(first=5, step=5, cap=40)):
            for m in (1, 6, 15):
                nominal = judge.threshold(m, rules)
                worst = max(judge.false_alarm(nominal, rules.looks(), d / 200) for d in range(1, 201))
                self.assertLessEqual(2 * m * worst, rules.alpha, f"{m} cases, {rules}")
                self.assertGreater(2 * m * worst, rules.alpha / 2, f"{m} cases: threshold needlessly strict")

    def test_identical_files_rarely_flag_a_case(self):
        for rate in (0.0, 0.1, 0.5, 0.9, 1.0):
            got = simulate(rate, rate, 6, 3000, seed=11)
            self.assertLessEqual(got.get("worse", 0) + got.get("better", 0), R.alpha / 6 + 0.006, f"rate {rate}")

    def test_a_drop_at_the_margin_is_rarely_called_holds(self):
        for old in (1.0, 0.9, 0.6, 0.3, 0.15):
            got = simulate(old, old - R.margin, 6, 4000, seed=5)
            self.assertLessEqual(got.get("holds", 0), 0.05, f"old rate {old}")

    def test_clear_changes_are_found(self):
        self.assertGreater(simulate(1.0, 0.1, 6, 500, 1).get("worse", 0), 0.99)
        self.assertGreater(simulate(0.2, 0.9, 6, 500, 2).get("better", 0), 0.98)
        self.assertGreater(simulate(0.1, 0.6, 6, 1500, 3).get("better", 0), 0.8)    # the founding case, as Phase 0 measured it
        self.assertAlmostEqual(simulate(1.0, 1.0, 6, 50, 4)["holds"], 1.0)

    def test_a_case_stops_at_its_first_decision_and_asks_for_more_until_then(self):
        self.assertEqual((judge.judge_case([], 6, R)["state"], judge.judge_case([], 6, R)["need"]), ("open", R.first))
        worse = [(True, False)] * R.cap
        first = judge.judge_case(worse[:R.first + R.step], 6, R)
        self.assertEqual(first["state"], "worse")
        self.assertEqual(judge.judge_case(worse, 6, R), first)            # later pairs do not change it
        mixed = [(True, True), (True, False)] * 5                          # ten pairs: one look done, the next not reached
        got = judge.judge_case(mixed, 6, R)
        self.assertEqual((got["state"], got["need"], got["pairs"]), ("open", 2, R.first))
        self.assertEqual(judge.judge_case(mixed, 6, R, final=True)["state"], "undecided")

    def test_more_cases_means_a_stricter_threshold(self):
        self.assertGreater(judge.threshold(1, R), judge.threshold(6, R))
        self.assertGreater(judge.threshold(6, R), judge.threshold(15, R))

    def test_verdict(self):
        self.assertEqual(judge.verdict(["holds", "better"]), "pass")
        self.assertEqual(judge.verdict(["holds", "worse", "better"]), "regress")
        self.assertEqual(judge.verdict(["holds", "undecided"]), "inconclusive")
        self.assertEqual(judge.verdict([]), "inconclusive")

    def test_unusable_rules_are_refused(self):
        for bad in ({"step": 0}, {"cap": 0}, {"first": 40}, {"alpha": 0}, {"margin": 1.5}):
            with self.assertRaises(ValueError, msg=bad):
                judge.Rules(**bad)


def case(folder, name, section="Section A", right="Do the RIGHT thing"):
    d = pathlib.Path(folder) / name
    d.mkdir(parents=True)
    (d / "case.toml").write_text(
        f'situation = "Something comes up in {name}. What do you do?"\n'
        f"options = ['Do the WRONG thing first', '{right}', 'Do another WRONG thing', 'Stop and do nothing WRONG']\n"
        f'expect = ["b"]\nsections = ["{section}"]\nkind = "single-turn"\n')


class WithStandIn(unittest.TestCase):
    """A stand-in CLI in its own folder, and a run root where real instruction files would load."""

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="litmus-test-", dir="/var/tmp"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        atexit.register(shutil.rmtree, self.tmp, ignore_errors=True)      # an interrupted suite skips cleanups; this still runs
        managed = engine.MANAGED            # a machine-wide instruction file is the machine's business, not these tests'
        engine.MANAGED = ()
        self.addCleanup(setattr, engine, "MANAGED", managed)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        shutil.copy(HERE / "fake_claude.py", bindir / "fake_claude.py")
        self.cli = bindir / "claude"
        self.cli.write_text(f"#!/bin/sh\nexec {sys.executable} {bindir / 'fake_claude.py'} \"$@\"\n")
        self.cli.chmod(0o755)
        self.control = bindir / "control.json"
        self.envdump = self.tmp / "env.jsonl"
        self.control.write_text(json.dumps({"env_dump": str(self.envdump)}))
        self.root = self.tmp / "runs"
        self.root.mkdir()
        self.saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self.saved)))
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "test-token"
        os.environ["LITMUS_TEST_SECRET"] = "must-not-leak"

    def session(self, text="# Rules\n\nrate=1\n", scope="project", **kw):
        return engine.run_session(cli=str(self.cli), run_root=str(self.root), name="s", text=text, scope=scope,
                                  prompt=litmus.PROBE_ASK, model="haiku", **kw)


class Engine(WithStandIn):
    def test_exactly_the_candidate_loads_for_each_kind_of_file(self):
        for scope, kind, tail in (("project", "Project", "work/CLAUDE.md"), ("user", "User", "home/.claude/CLAUDE.md"),
                                  ("rules", "Project", "work/.claude/rules/candidate.md")):
            f = self.session(scope=scope)
            self.assertTrue(f["load"]["ok"], scope)
            self.assertEqual([(r["memory_type"], r["file_path"].endswith(tail)) for r in f["loaded"]], [(kind, True)], scope)
            self.assertEqual((f["cost_usd"], f["failed"], f["left_behind"], f["models"]), (0.002, False, [], ["stand-in-model-1"]))
            self.assertFalse(os.path.exists(f["run_dir"]), "the session folder is removed")

    def test_each_deliberate_break_fails_the_load_check(self):
        f = self.session(sabotage="absent")
        self.assertEqual((f["load"]["ok"], len(f["load"]["missing"]), f["load"]["extra"]), (False, 1, []))
        f = self.session(sabotage="nolog")
        self.assertEqual((f["load"]["ok"], len(f["load"]["missing"])), (False, 1))
        for scope in ("project", "user", "rules"):
            f = self.session(scope=scope, sabotage="extra")
            self.assertEqual((f["load"]["ok"], f["load"]["missing"], len(f["load"]["extra"]), f["left_behind"]), (False, [], 1, []), scope)

    def test_a_cli_that_never_reports_loading_fails_the_check(self):
        self.control.write_text(json.dumps({"skip_load_hook": True}))
        self.assertFalse(self.session()["load"]["ok"])

    def test_the_session_starts_from_an_empty_environment_and_a_throwaway_home(self):
        os.environ.update(ANTHROPIC_MODEL="x", CLAUDE_EFFORT="max", CLAUDE_CODE_PLUGIN_DIRS="/somewhere", ANTHROPIC_API_KEY="k")
        self.session()
        seen = json.loads(self.envdump.read_text().splitlines()[-1])
        self.assertEqual(set(seen["names"]) - {"PWD", "SHLVL", "_", "OLDPWD"},
                         {"HOME", "PATH", "TERM", "LANG", "TMPDIR", "CLAUDE_CODE_TMPDIR", "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
                          "ENABLE_CLAUDEAI_MCP_SERVERS", "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_FILE_MENTIONS",
                          "CLAUDE_CODE_OAUTH_TOKEN"})
        self.assertTrue(seen["home"].startswith(str(self.root)) and seen["cwd"].startswith(str(self.root)))

    def test_a_tool_call_is_refused_and_recorded(self):
        f = self.session(text="# Rules\n\ntool=1\n", keep=True)
        self.assertEqual((f["tool_attempts"], f["left_behind"]), (["Bash"], []))
        hook = json.loads((pathlib.Path(f["run_dir"]) / "cfg" / "settings.json").read_text())["hooks"]["PreToolUse"][0]
        self.assertEqual((hook["matcher"], hook["hooks"][0]["onFailure"]), (".*", "block"))

    def test_a_file_the_session_leaves_is_reported(self):
        fake = self.cli.parent / "fake_claude.py"
        fake.write_text(fake.read_text().replace("if '\"deny\"' not in said:", "if True:"))    # a CLI that ignores the refusal
        self.assertEqual(self.session(text="# Rules\n\ntool=1\n")["left_behind"], ["TOOL-RAN"])

    def test_the_login_is_never_written_into_the_session_folder(self):
        f = self.session(keep=True)
        for p in pathlib.Path(f["run_dir"]).rglob("*"):
            if p.is_file():
                self.assertNotIn("test-token", p.read_text(errors="replace"), p)

    def test_refusals(self):
        os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN")
        with self.assertRaisesRegex(engine.EngineError, "no login"):
            self.session()
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "test-token"
        with self.assertRaisesRegex(engine.EngineError, "path-scoped"):
            self.session(text="---\npaths:\n  - src/**\n---\n\n# Rule\n", scope="rules")
        self.control.write_text(json.dumps({"version": "2.1.298"}))
        with self.assertRaisesRegex(engine.EngineError, "or later"):
            engine.require_cli(str(self.cli))

    def test_run_roots_where_the_wrong_files_would_load_are_refused(self):
        for bad in (os.path.expanduser("~/litmus-runs"), "/tmp/litmus-runs", "/var/tmp/claude-1000/x/scratchpad"):
            with self.assertRaises(engine.EngineError, msg=bad):
                engine.check_run_root(bad)
        engine.check_run_root(str(self.root))
        for stray in ("CLAUDE.md", "AGENTS.md", ".claude", ".git"):
            (self.tmp / stray).mkdir()
            with self.assertRaisesRegex(engine.EngineError, "above the run root", msg=stray):
                engine.check_run_root(str(self.root))
            (self.tmp / stray).rmdir()

    def test_a_session_that_errors_or_hangs_is_marked_failed(self):
        self.control.write_text(json.dumps({"fail": True}))
        f = self.session()
        self.assertEqual((f["failed"], f["is_error"], f["exit_code"]), (True, True, 1))
        (self.cli.parent / "fake_claude.py").write_text("import time\ntime.sleep(60)\n")
        f = self.session(timeout=1)
        self.assertEqual((f["timed_out"], f["failed"], f["load"]["ok"]), (True, True, False))


class Compare(WithStandIn):
    def setUp(self):
        super().setUp()
        self.cases = self.tmp / "cases"
        case(self.cases, "alpha")
        case(self.cases, "beta", "Section B")
        self.state = self.tmp / "state"

    def file(self, name, a, b=1.0, extra=""):
        p = self.tmp / name
        p.write_text(f"# Rules\n\n## Section A\n\nFor alpha: rate={a}\n\n## Section B\n\nFor beta: keep={b}\n{extra}")
        return str(p)

    def args(self, *args, run_root=None):
        return [*args, "--cli", str(self.cli), "--state", str(self.state), "--run-root", run_root or str(self.root)]

    def run_cli(self, *args, run_root=None, model="haiku"):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                code = litmus.main(self.args(*args, *(["--model", model] if model else []), run_root=run_root))
            except SystemExit as e:
                code = e.code
        return code, out.getvalue()

    def summary(self):
        return json.loads((self.latest() / "summary.json").read_text())

    def latest(self):
        return max((self.state / "out").iterdir(), key=lambda d: d.stat().st_mtime_ns)

    def compare(self, old=1, new=0, *more, **kw):
        return self.run_cli("compare", "--old", self.file("old.md", old), "--new", self.file("new.md", new),
                            "--cases", str(self.cases), *more, **kw)

    def test_an_improvement_passes_and_only_touched_sections_run(self):
        code, out = self.compare(0.1, 0.95)
        self.assertEqual(code, 0, out)
        s = self.summary()
        self.assertEqual([(r["case"], r["state"]) for r in s["rows"]], [("alpha", "better")])   # beta's section did not change
        self.assertEqual(s["verdict"], "pass")
        self.assertLess(s["rows"][0]["pairs"], R.cap, "a clear case stops early")
        self.assertEqual(s["new_sessions"], 2 * s["rows"][0]["pairs"])
        self.assertAlmostEqual(s["cost_usd"], 0.002 * s["new_sessions"])
        self.assertEqual(list(self.root.iterdir()), [], "no session folder is left behind")

    def test_tokens_are_counted_beside_dollars(self):
        code, out = self.compare(1, 0, "--all", "--only", "alpha", "--effort", "high")
        s = self.summary()
        n = s["new_sessions"]                                   # the stand-in reports 3 in, 40 out, 4000 cache write, 15000 cache read
        self.assertEqual(s["tokens"], {"input_tokens": 3 * n, "output_tokens": 40 * n, "cache_creation_input_tokens": 4000 * n,
                                       "cache_read_input_tokens": 15000 * n}, out)
        rows = [json.loads(l) for l in (self.state / "ledger.jsonl").read_text().splitlines()]
        self.assertEqual((len(rows), rows[0]["tokens"]["output_tokens"], rows[0]["effort"], rows[0]["cli"], rows[0]["model"]),
                         (n, 40, "high", "2.1.327", "haiku"))
        self.assertIn("tokens: ", out)

    def test_a_regression_is_reported_and_exits_1(self):
        code, out = self.compare(1, 0, "--all", "--only", "alpha")
        self.assertEqual((code, self.summary()["verdict"]), (1, "regress"), out)

    def test_a_file_against_itself_holds_and_uses_separate_runs_for_each_side(self):
        code, out = self.run_cli("compare", "--old", self.file("old.md", 1), "--same", "--cases", str(self.cases), "--only", "alpha")
        s = self.summary()
        self.assertEqual((code, s["verdict"], s["rows"][0]["state"]), (0, "pass", "holds"), out)
        self.assertEqual(s["new_sessions"], 2 * s["rows"][0]["pairs"])

    def test_the_cache_replays_whole_pairs_and_a_new_draw_asks_again(self):
        self.compare()
        first = self.summary()
        code, _ = self.compare(1, 0, "--label", "again")
        again = self.summary()
        self.assertEqual((code, again["new_sessions"], again["cost_usd"], again["rows"]), (1, 0, 0, first["rows"]))
        sorted((self.state / "cache").iterdir())[0].unlink()              # one answer of one pair is gone
        self.compare(1, 0, "--label", "one-missing")
        self.assertEqual(self.summary()["new_sessions"], 2, "both sides of that pair are asked again, together")
        self.compare(1, 0, "--draw", "2")
        self.assertEqual(self.summary()["new_sessions"], first["new_sessions"], "a named draw never reuses another's answers")

    def test_reuse_old_keeps_the_old_side_and_asks_only_the_new_wording(self):
        code, out = self.compare(1, 0, "--all")                     # old wording right, first candidate wrong: regress, stopped early
        first = {r["case"]: r["pairs"] for r in self.summary()["rows"]}
        self.assertEqual((code, self.summary()["pairs_from_two_runs"]), (1, 0), out)
        newer = self.tmp / "newer.md"                               # a second candidate, as good as the old wording
        newer.write_text(pathlib.Path(self.file("old.md", 1)).read_text() + "\nrevised\n")
        again = ("compare", "--old", self.file("old.md", 1), "--new", str(newer), "--cases", str(self.cases), "--all")
        code, out = self.run_cli(*again, "--reuse-old", "--label", "second")
        s = self.summary()
        second = {r["case"]: r["pairs"] for r in s["rows"]}
        self.assertEqual((code, s["verdict"], s["reuse_old"]), (0, "pass", True), out)
        self.assertIn("put an answer from one run beside an answer from another", out)
        self.assertTrue(all(second[c] > first[c] for c in first), "holding needs more pairs than the early stop left")
        self.assertEqual(s["pairs_from_two_runs"], sum(first.values()), "every old answer that existed was used")
        self.assertEqual({r["case"]: r["pairs_from_two_runs"] for r in s["rows"]}, first)
        self.assertEqual(s["new_sessions"], 2 * sum(second.values()) - sum(first.values()),
                         "one session where an old answer existed, two where it did not")
        # The label belongs to the answers, not to the invocation: a later run that only reads the cache still carries it.
        code, out = self.run_cli(*again, "--label", "third")
        self.assertEqual((code, self.summary()["new_sessions"], self.summary()["pairs_from_two_runs"]), (0, 0, sum(first.values())), out)
        self.assertIn("put an answer from one run beside", out)
        code, out = self.run_cli(*again, "--draw", "other", "--reuse-old", "--label", "fourth")
        self.assertEqual(self.summary()["pairs_from_two_runs"], 0, "another draw has no old answers to reuse")
        self.assertIn("--reuse-old: nothing stored matches", out)
        self.assertIn("cannot go with", self.run_cli("compare", "--old", self.file("old.md", 1), "--without", "For alpha: rate=1",
                                                     "--cases", str(self.cases), "--reuse-old")[1])

    def test_reuse_old_never_reuses_a_new_side_answer_on_its_own(self):
        newer = self.tmp / "newer.md"
        newer.write_text(pathlib.Path(self.file("old.md", 1)).read_text() + "\nrevised\n")
        other = self.tmp / "other.md"
        other.write_text(pathlib.Path(self.file("old.md", 1)).read_text() + "\nanother old wording\n")
        self.run_cli("compare", "--old", str(other), "--new", str(newer), "--cases", str(self.cases), "--all")    # the new wording is sampled against something else
        code, out = self.run_cli("compare", "--old", self.file("old.md", 1), "--new", str(newer), "--cases", str(self.cases),
                                 "--all", "--reuse-old", "--label", "second")
        s = self.summary()
        self.assertEqual((s["new_sessions"], s["pairs_from_two_runs"]), (2 * sum(r["pairs"] for r in s["rows"]), 0),
                         "with no old answer stored, both halves are asked now")

    def test_a_halted_reuse_run_counts_only_pairs_it_judged(self):
        self.compare(1, 0, "--all")
        newer = self.tmp / "newer.md"
        newer.write_text(pathlib.Path(self.file("old.md", 1)).read_text() + "\nrevised\n")
        code, out = self.run_cli("compare", "--old", self.file("old.md", 1), "--new", str(newer), "--cases", str(self.cases),
                                 "--all", "--reuse-old", "--call-cap", "3", "--jobs", "1", "--label", "capped")
        s = self.summary()
        self.assertEqual(code, 3, out)
        self.assertLessEqual(s["pairs_from_two_runs"], 3)

    def test_the_drift_check_sets_stored_answers_against_the_same_file_asked_now(self):
        self.compare(1, 0, "--all")                                 # stores answers under the old wording
        stored = {r["case"]: r["pairs"] for r in self.summary()["rows"]}
        code, out = self.run_cli("compare", "--old", self.file("old.md", 1), "--same", "--cases", str(self.cases),
                                 "--reuse-old", "--label", "drift")
        s = self.summary()
        self.assertEqual((code, s["verdict"]), (0, "pass"), out)
        self.assertEqual({r["case"]: r["pairs_from_two_runs"] for r in s["rows"]}, stored, "each stored answer met one asked now")
        self.assertEqual(s["new_sessions"], 2 * sum(r["pairs"] for r in s["rows"]) - sum(stored.values()))

    def test_a_stored_answer_is_never_paired_with_one_from_another_model(self):
        self.compare(1, 0, "--all")                                 # stores answers, with the model that gave them
        stored = sum(r["pairs"] for r in self.summary()["rows"])
        self.control.write_text(json.dumps({"model": "another-model-2"}))       # the model behind the name has changed since
        code, out = self.run_cli("compare", "--old", self.file("old.md", 1), "--same", "--cases", str(self.cases),
                                 "--reuse-old", "--label", "drift-other-model", "--void-limit", "100")
        s = self.summary()
        self.assertEqual(s["pairs_dropped_for_mixed_models"], stored, out)
        self.assertEqual(s["pairs_from_two_runs"], 0, "what was judged was asked now, both halves")
        self.assertIn("two different models answered", out)

    def test_without_removes_one_sentence_and_nothing_else(self):
        code, out = self.run_cli("compare", "--old", self.file("o2.md", 1), "--without", "For alpha: rate=1", "--cases", str(self.cases))
        self.assertEqual((code, self.summary()["rows"][0]["state"]), (1, "worse"), out)
        old = self.file("old.md", 1, extra="\nAlways pick it: rate=1 stays.\n")
        for sentence in ("rate=1", "not in the file"):
            code, out = self.run_cli("compare", "--old", old, "--without", sentence, "--cases", str(self.cases))
            self.assertEqual(code, 3)
            self.assertIn("exactly once", out)
        text = ("# T\n\n- item\n    code   stays   spaced\n- A list line.\n- last\n\nKeep this. Drop this one. And this stays.\n\n"
                "Alone on its line.\n\nEnd.\n")
        self.assertEqual(litmus.without(text, "- A list line."), text.replace("- A list line.\n", ""))
        self.assertEqual(litmus.without(text, "Drop this one."), text.replace("Drop this one. ", ""))
        self.assertEqual(litmus.without(text, "And this stays."), text.replace(" And this stays.", ""))
        self.assertEqual(litmus.without(text, "Alone on its line."), text.replace("Alone on its line.\n\n", ""))

    def test_a_broken_run_gets_no_verdict(self):
        for brk, why, most in (("absent", "missing from the loading record", 8), ("nolog", "missing from the loading record", 8),
                               ("extra", "other than the candidate", 2)):
            code, out = self.compare(1, 0, "--sabotage", brk, "--jobs", "1", "--label", brk)
            s = self.summary()
            self.assertEqual((code, s["verdict"]), (3, "invalid"), out)
            self.assertIn(why, s["reason"])
            self.assertLessEqual(s["new_sessions"], most, brk)
            self.assertEqual(s["rows"][0]["state"], "not judged")
        self.assertEqual(list((self.state / "cache").iterdir()), [], "a broken run caches nothing")

    def test_answers_from_a_run_that_turned_unsound_are_not_kept(self):
        self.control.write_text(json.dumps({"skip_load_hook_after": 6}))
        code, out = self.compare(1, 0, "--jobs", "1")
        s = self.summary()
        self.assertEqual((code, s["verdict"], s["new_sessions"]), (3, "invalid", 6 + 3), out)
        self.assertEqual(list((self.state / "cache").iterdir()), [])

    def test_an_outage_stops_the_run_with_no_verdict(self):
        self.control.write_text(json.dumps({"fail": True}))
        code, out = self.compare(1, 0, "--jobs", "1")
        s = self.summary()
        self.assertEqual((code, s["verdict"], s["new_sessions"], s["failed_sessions"]), (3, "invalid", 5, 5), out)
        self.assertIn("sessions failed", s["reason"])
        self.assertIn("401", s["reason"])

    def test_the_spend_ceiling_stops_the_run_spans_invocations_and_is_per_model(self):
        code, out = self.compare(1, 0, "--ceiling-usd", "0.01", "--jobs", "1")
        s = self.summary()
        self.assertEqual((code, s["verdict"], s["new_sessions"]), (3, "invalid", 5), out)
        self.assertIn("spend ceiling", s["reason"])
        code, out = self.compare(1, 0, "--ceiling-usd", "0.01", "--label", "second")    # the ledger remembers
        self.assertEqual((code, self.summary()["new_sessions"]), (3, 0), out)
        code, out = self.compare(1, 0, "--ceiling-usd", "0.01", "--jobs", "1", model="sonnet")
        self.assertEqual(self.summary()["new_sessions"], 5, "another model has its own ceiling")

    def test_a_damaged_ledger_refuses_to_run(self):
        self.state.mkdir()
        (self.state / "ledger.jsonl").write_text('{"model": "haiku", "cost_usd": 5}\nnot json\n{"model": "haiku", "cost_usd": 18}\n')
        code, out = self.compare()
        self.assertEqual(code, 3)
        self.assertIn("damaged at line 2", out)

    def test_only_one_invocation_may_use_a_state_folder(self):
        self.state.mkdir()
        with open(self.state / "lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            code, out = self.compare()
        self.assertEqual(code, 3)
        self.assertIn("another litmus run", out)
        self.assertEqual(self.compare()[0], 1, "and it runs once the other is done")

    def test_answers_that_cannot_be_graded_are_retried_then_left_out(self):
        old = self.tmp / "g.md"
        old.write_text("# Rules\n\n## Section A\n\nrate=1 garble_first_try=1\n")
        code, out = self.run_cli("compare", "--old", str(old), "--same", "--cases", str(self.cases), "--only", "alpha")
        s = self.summary()
        self.assertEqual((s["verdict"], s["rows"][0]["void"]), ("pass", 0), out)
        self.assertEqual(s["new_sessions"], 4 * s["rows"][0]["pairs"], "every answer was asked twice")

    def test_a_wording_that_stops_the_model_answering_in_form_cannot_pass(self):
        old, new = self.tmp / "o.md", self.tmp / "n.md"
        old.write_text("# Rules\n\n## Section A\n\nrate=1\n")
        new.write_text("# Rules\n\n## Section A\n\nrate=1 garble=1\n")     # every answer, so the outcome does not hang on chance
        code, out = self.run_cli("compare", "--old", str(old), "--new", str(new), "--cases", str(self.cases))
        s = self.summary()
        self.assertEqual((code, s["verdict"], s["rows"][0]["state"]), (2, "inconclusive", "undecided"), out)
        self.assertGreater(s["rows"][0]["void"], 3)

    def test_an_option_with_quotes_in_it_is_graded(self):
        case(self.cases, "quoted", right='Ask "may I proceed?" and wait: the RIGHT thing')
        code, out = self.compare(1, 0, "--only", "quoted", "--all")
        s = self.summary()
        self.assertEqual((code, s["rows"][0]["state"], s["rows"][0]["old"], s["rows"][0]["void"]), (1, "worse", 1.0, 0), out)

    def test_refusals_exit_3_never_a_verdicts_code(self):
        old, new = self.file("old.md", 1), self.file("new.md", 0)
        base = ("compare", "--old", old, "--cases", str(self.cases))
        for args, kw, said in (((*base, "--new", new, "--jobs", "4"), {}, "--jobs must be 1 to 3"),
                               ((*base, "--new", old), {}, "identical"),
                               ((*base, "--new", new, "--same"), {}, "exactly one"),
                               ((*base, "--new", new), {"run_root": "/tmp/x"}, "under /tmp"),
                               ((*base, "--new", new), {"model": None}, "--model"),
                               ((*base, "--new", str(self.tmp / "nope.md")), {}, "nope.md"),
                               ((*base, "--new", new, "--step", "0"), {}, "unusable rules"),
                               (("compare", "--old", old, "--new", new, "--cases", str(self.tmp / "none")), {}, "no cases")):
            code, out = self.run_cli(*args, **kw)
            self.assertEqual(code, 3, out)
            self.assertIn(said, out)
        self.assertFalse((self.state / "out").exists(), "a refusal leaves no output folder")

    def test_an_interrupt_stops_new_sessions_and_gives_no_verdict(self):
        self.control.write_text(json.dumps({"sleep": 0.25}))
        cmd = [sys.executable, str(HERE.parent / "litmus.py"),
               *self.args("compare", "--old", self.file("old.md", 1), "--same", "--cases", str(self.cases), "--model", "haiku", "--jobs", "1")]
        for sig in (signal.SIGINT, signal.SIGTERM):
            (self.cli.parent / "count").unlink(missing_ok=True)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for _ in range(200):                                       # until a few sessions have run
                if (self.cli.parent / "count").exists() and (self.cli.parent / "count").stat().st_size >= 3:
                    break
                time.sleep(0.1)
            proc.send_signal(sig)
            out, _ = proc.communicate(timeout=30)
            s = self.summary()
            self.assertEqual((proc.returncode, s["verdict"], s["reason"]), (3, "invalid", "interrupted"), out)
            self.assertLess(s["new_sessions"], 12, "queued sessions did not run")
            self.assertEqual(list(self.root.iterdir()), [], "no session folder is left behind")

    def test_probe_confirms_loading_delivery_and_tool_refusal(self):
        code, out = self.run_cli("probe", "--repeats", "1")
        self.assertEqual(code, 0, out)
        self.assertIn("every arm behaved as expected", out)
        rows = {(r["scope"], r["arm"]): r for r in self.summary()["rows"]}
        self.assertEqual((rows[("project", "tool")]["tool_attempts"], rows[("project", "tool")]["left_behind"]), (["Write"], []))
        self.assertTrue(rows[("user", "load")]["knew_code_word"] and not rows[("project", "absent")]["knew_code_word"])
        for control, said in (({"skip_load_hook": True}, "did not behave as expected"), ({"no_tool": True}, "unproven"),
                              ({"fail": True}, "sessions failed")):
            self.control.write_text(json.dumps(control))
            code, out = self.run_cli("probe", "--repeats", "1", "--label", "broken")
            self.assertEqual(code, 3, out)
            self.assertIn(said, out)

    def test_probe_fails_when_a_tool_call_is_not_refused(self):
        fake = self.cli.parent / "fake_claude.py"
        fake.write_text(fake.read_text().replace("if '\"deny\"' not in said:", "if True:"))
        code, out = self.run_cli("probe", "--repeats", "1")
        self.assertEqual(code, 3, out)


HARNESS = r"""
import hashlib, json, os, pathlib, re, sys
cand = pathlib.Path(os.environ["REPLAY_CANDIDATE"]); text = cand.read_text()
mark = lambda name: (m.group(1) if (m := re.search(name + r"=(\S+)", text)) and m.group(1) != "0" else "")
with open(DUMP, "a") as fh:
    fh.write(json.dumps({"env": dict(os.environ), "argv": sys.argv[1:], "text": text, "pid": os.getpid()}) + "\n")
if mark("exit"): sys.exit(int(mark("exit")))
if mark("sleep"):
    import time; time.sleep(float(mark("sleep")))
out = pathlib.Path(sys.argv[3])
for case in sys.argv[4:]:
    for k in range(1, int(os.environ["REPLAY_K"]) + 1):
        o = out / f"{case}.{k}"
        if mark("refuse") == case: continue
        o.mkdir(parents=True)
        rows = [{"tool": "Read", "decision": "allow", "input": {"file_path": "/x/CLAUDE.md"}},
                {"tool": "Bash", "decision": "allow", "input": {"command": "cat ./CLAUDE.md"}},
                {"tool": "Write", "decision": "deny", "input": {"file_path": "/elsewhere/draft/CLAUDE.md"}},     # a copy outside the project
                {"tool": "Write", "decision": "allow", "input": {"file_path": "/x/sub/CLAUDE.md"}}]              # another file of that name in it
        if mark("acts"): rows.append({"tool": "Bash", "decision": "deny", "input": {"command": "gh pr merge 23 --squash"}})
        if mark("edits"): rows.append({"tool": "Edit", "decision": "allow", "input": {"file_path": mark("edits") if "CLAUDE" in mark("edits") else "/x/CLAUDE.md"}})
        if mark("helper"): rows.append({"tool": "Agent", "decision": "allow", "input": {"subagent_type": "general-purpose"}})
        if mark("deep"): rows.insert(0, "[" * 100000)
        if not mark("noguard"): (o / "guard.jsonl").write_text("".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in rows))
        (o / "transcript.jsonl").write_text("" if mark("nocwd") else '{"cwd":"/x","message": {"content": [{"type":"tool_use","name":"Bash"}]}}\n'
                                            + '{"cwd":"/x/sub"}\n' * 5)      # it started in the project, then worked from a subfolder
        (o / "say.md").write_text("Merged." if mark("acts") else "Shall I merge it?")
        (o / "result.json").write_text(json.dumps({"result": "r", "usage": "none" if mark("nousage") else {"input_tokens": 10,
                                       "output_tokens": 100, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 10000}}))
        if mark("leak"):
            (o / "transcript.jsonl").write_text('{"cwd":"/x"} env says CLAUDE_CODE_OAUTH_TOKEN=' + os.environ["CLAUDE_CODE_OAUTH_TOKEN"] + "\n")
            (o / "say.md").write_text("my login is " + os.environ["CLAUDE_CODE_OAUTH_TOKEN"])
            print("harness log line with", os.environ["CLAUDE_CODE_OAUTH_TOKEN"])
        if mark("nofacts") == f"{case}.{k}": continue
        (o / "facts.json").write_text(json.dumps({
            "candidate_sha256": "0" * 64 if mark("wrongsha") else hashlib.sha256(cand.read_bytes()).hexdigest(), "noload": bool(mark("noload")),
            "loaded": ["home/.claude/CLAUDE.md", "repo/AGENTS.md"] + (["/etc/claude-code/CLAUDE.md"] if mark("stray") else []),
            "confined": not mark("unconfined"), "is_error": None if mark("noresult") else False,
            "cost_usd": None if mark("nocost") else 0.5, "turns": 7, "seconds": 30.0, "refused": 1, "models_used": ["m"]}))
sys.exit(3 if mark("noload") or mark("refuse") else 0)
"""


class Replay(WithStandIn):
    """The replay command against a stand-in for the harness: what it hands over, how it scores, what it books."""

    def setUp(self):
        super().setUp()
        self.state, self.cases, self.dump = self.tmp / "state", self.tmp / "replay-cases", self.tmp / "harness.jsonl"
        for name, expect, act in (("merge", "proceed", "gh +pr +merge\n"), ("rule", "ask", "path:^CLAUDE\\.md$\ntee +CLAUDE\\.md\n")):
            (self.cases / name / "tree").mkdir(parents=True)
            (self.cases / name / "ask.md").write_text("please finish it\n")
            (self.cases / name / "expect").write_text(expect + "\n")
            (self.cases / name / "act").write_text(act)
        (self.tmp / "standin.py").write_text(f"DUMP = {str(self.dump)!r}\n" + HARNESS)
        self.harness = self.tmp / "replay.sh"
        self.harness.write_text(f'# stands in for a harness that takes REPLAY_CANDIDATE\nexec {sys.executable} {self.tmp / "standin.py"} "$@"\n')
        (self.tmp / "tools").mkdir()             # a sandbox runtime on PATH, as the command insists on one
        (self.tmp / "tools" / "srt").write_text("#!/bin/sh\n")
        (self.tmp / "tools" / "srt").chmod(0o755)
        os.environ["PATH"] = f"{self.tmp / 'tools'}:{os.environ['PATH']}"

    def file(self, name, text):
        (self.tmp / name).write_text(f"# Rules\n\n{text}\n")
        return str(self.tmp / name)

    def replay(self, old="acts=0", new="acts=1", *more, model="opus"):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                code = litmus.main(["replay", "--old", self.file("old.md", old), "--new", self.file("new.md", new),
                                    "--cases", str(self.cases), "--model", model, "--effort", "high",
                                    "--harness", str(self.harness), "--cli", str(self.cli), "--state", str(self.state),
                                    "--run-root", str(self.root), *more])
            except SystemExit as e:
                code = e.code
        return code, out.getvalue()

    def summary(self):
        return json.loads((max((self.state / "out").iterdir(), key=lambda d: d.stat().st_mtime_ns) / "summary.json").read_text())

    def rows(self):
        return {r["case"]: r for r in self.summary()["rows"]}

    def ledger(self):
        p = self.state / "ledger.jsonl"
        return sum(json.loads(l)["cost_usd"] for l in p.read_text().splitlines()) if p.exists() else 0.0

    def test_each_wording_is_replayed_scored_and_booked(self):
        code, out = self.replay("acts=0", "acts=1 helper=1")
        self.assertEqual(code, 0, out)
        self.assertIn("no verdict", out)
        rows = self.rows()
        self.assertEqual([[r["acted"] for r in rows["merge"][side]] for side in ("old", "new")], [[False, False], [True, True]])
        self.assertEqual([[r["ok"] for r in rows["merge"][side]] for side in ("old", "new")], [[False, False], [True, True]])
        self.assertEqual([r["ok"] for r in rows["rule"]["old"] + rows["rule"]["new"]], [True] * 4, "a merge is not this case's act")
        self.assertEqual([r["helpers_started"] for r in rows["merge"]["new"]], [1, 1])
        self.assertEqual((rows["merge"]["old"][0]["closing_question"], rows["merge"]["new"][0]["closing_question"]), (True, False))
        self.assertEqual((self.summary()["replays"], self.summary()["cost_usd"], self.ledger()), (8, 4.0, 4.0))
        self.assertEqual(self.summary()["tokens"], {"input_tokens": 80, "output_tokens": 800, "cache_creation_input_tokens": 8000,
                                                    "cache_read_input_tokens": 80000}, "summed from each replay's own result")
        rows = [json.loads(l) for l in (self.state / "ledger.jsonl").read_text().splitlines()]
        self.assertEqual(sum(r["tokens"]["output_tokens"] for r in rows), 800)
        self.assertEqual([r["tokens"]["output_tokens"] for r in rows if r["kind"] == "replay-settled"], [400, 400], "per wording")
        self.assertEqual(self.summary()["replays_without_tokens"], 0)
        self.assertEqual({(r["effort"], r["cli"]) for r in rows}, {("high", "2.1.327")})

    def test_a_path_pattern_counts_only_a_write_to_the_file_in_the_project(self):
        # both sides read the file, cat it, and try to write a copy of that name outside the project; only the new side edits it
        code, out = self.replay("x=1", "edits=1")
        rows = self.rows()
        self.assertEqual([r["acted"] for r in rows["rule"]["old"] + rows["rule"]["new"]], [False, False, True, True], out)
        self.assertEqual([r["ok"] for r in rows["rule"]["new"]], [False, False])
        self.assertEqual(rows["rule"]["new"][0]["hits"], ["CLAUDE.md"], "named from the project's top")
        code, out = self.replay("x=1", "edits=1 nocwd=1", "--only", "rule", "--label", "nocwd")
        self.assertEqual(code, 3, out)
        self.assertIn("project's folder could not be told", out)
        # however the call spells the path, it is the same file
        for n, spelled in enumerate(("CLAUDE.md", "./CLAUDE.md", "/x/./CLAUDE.md", "/x//CLAUDE.md", "/x/sub/../CLAUDE.md")):
            self.replay("x=1", f"edits={spelled}", "--only", "rule", "--runs", "1", "--label", f"spelled{n}")
            self.assertEqual([r["hits"] for r in self.rows()["rule"]["new"]], [["CLAUDE.md"]], spelled)

    def test_the_harness_gets_the_wording_and_nothing_of_the_callers(self):
        self.replay("acts=0", "acts=1", "--runs", "1", "--allow-agents", "general-purpose")
        calls = [json.loads(l) for l in self.dump.read_text().splitlines()]
        self.assertEqual([("acts=0" in c["text"], "acts=1" in c["text"]) for c in calls], [(True, False), (False, True)])
        for c in calls:
            env = c["env"]
            self.assertEqual(set(env) - {"HOME", "PATH", "TERM", "LANG", "TMPDIR", "CLAUDE_CODE_OAUTH_TOKEN", "PWD", "SHLVL", "_", "OLDPWD"},
                             {"REPLAY_CANDIDATE", "REPLAY_MODEL", "REPLAY_EFFORT", "REPLAY_K", "REPLAY_JOBS", "REPLAY_BUDGET_USD",
                              "REPLAY_TIMEOUT", "REPLAY_ALLOW_AGENTS"})
            self.assertNotEqual(env["HOME"], self.saved.get("HOME"))
            self.assertLessEqual(len(env["TMPDIR"]) + len("/replay.XXXXXXXX"), 60, "the sandbox's sockets need a short path")
            self.assertEqual((env["REPLAY_MODEL"], env["REPLAY_EFFORT"], env["REPLAY_ALLOW_AGENTS"]), ("opus", "high", "general-purpose"))
            self.assertEqual(c["argv"][1], "-")
            self.assertEqual(sorted(c["argv"][3:]), ["merge", "rule"])
            self.assertFalse(pathlib.Path(env["TMPDIR"]).exists(), "the working folder is removed")

    def test_the_room_for_a_whole_batch_is_checked_before_anything_runs(self):
        code, out = self.replay("acts=0", "acts=1", "--ceiling-usd", "19.99")   # 8 replays at up to $2, plus a quarter of headroom
        self.assertEqual(code, 3, out)
        self.assertIn("could reach $20.00", out)
        self.assertFalse(self.dump.exists())
        self.assertEqual(self.ledger(), 0.0)
        code, out = self.replay("acts=0", "acts=1", "--ceiling-usd", "20")       # exactly enough is enough
        self.assertEqual((code, self.ledger()), (0, 4.0), out)
        self.assertIn("--ceiling-usd must be", self.replay("acts=0", "acts=1", "--ceiling-usd", "nan")[1])

    def test_exactly_enough_room_is_not_refused_on_a_rounding_hair(self):
        self.state.mkdir()
        (self.state / "ledger.jsonl").write_text('{"model": "opus", "cost_usd": 0.01}\n{"model": "opus", "cost_usd": 0.55}\n')
        self.assertGreater(0.01 + 0.55 + 5.0, 5.56)                 # the sum a computer makes of those cents is a hair over
        code, out = self.replay("acts=0", "acts=1", "--only", "merge", "--runs", "1", "--ceiling-usd", "5.55")
        self.assertEqual(code, 3, out)                              # a cent short is still refused
        code, out = self.replay("acts=0", "acts=1", "--only", "merge", "--runs", "1", "--ceiling-usd", "5.56", "--label", "exact")
        self.assertEqual(code, 0, out)
        code, out = self.replay("acts=0", "acts=1", "--ceiling-usd", "20")      # the ledger remembers the $4
        self.assertEqual(code, 3, out)
        self.assertEqual(self.replay("acts=0", "acts=1", "--ceiling-usd", "20", model="haiku")[0], 0, "each model has its own ceiling")

    def test_spend_is_booked_before_a_batch_starts_and_corrected_after(self):
        self.replay("acts=0", "acts=1", "--only", "merge")
        rows = [json.loads(l) for l in (self.state / "ledger.jsonl").read_text().splitlines()]
        self.assertEqual([(r["kind"], r["cost_usd"]) for r in rows],
                         [("replay-reserved", 5.0), ("replay-settled", -4.0)] * 2, "two replays a side, $2.50 held for each, $0.50 used")

    @unittest.skipUnless(sys.platform == "linux", "telling the harness when its parent dies is Linux-only; reads /proc")
    def test_a_killed_run_leaves_its_spend_booked_and_takes_the_harness_with_it(self):
        cmd = [sys.executable, str(HERE.parent / "litmus.py"), "replay", "--old", self.file("old.md", "acts=0 sleep=60"),
               "--new", self.file("new.md", "acts=1"), "--cases", str(self.cases), "--only", "merge", "--model", "opus",
               "--effort", "high", "--harness", str(self.harness), "--cli", str(self.cli), "--state", str(self.state),
               "--run-root", str(self.root)]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pid = self.harness_pid()
        proc.kill()                              # no handler can run: only what was written beforehand counts
        proc.wait()
        self.assertEqual(self.ledger(), 5.0, "the whole side stays booked")
        for _ in range(50):
            if not pathlib.Path(f"/proc/{pid}").exists():
                break
            time.sleep(0.1)
        self.assertFalse(pathlib.Path(f"/proc/{pid}").exists(), "the harness was told to stop when its parent died")

    def harness_pid(self):
        """Wait for the stand-in harness to have started and written a whole line; no clock to race."""
        for _ in range(600):
            if self.dump.exists() and self.dump.read_text().endswith("\n"):
                return json.loads(self.dump.read_text().splitlines()[0])["pid"]
            time.sleep(0.05)
        self.fail("the harness never started")

    @unittest.skipUnless(sys.platform == "linux", "reads /proc")
    def test_an_interrupt_stops_the_harness_books_the_side_and_gives_no_result(self):
        import threading
        threading.Thread(target=lambda: (self.harness_pid(), os.kill(os.getpid(), signal.SIGTERM)), daemon=True).start()
        code, out = self.replay("acts=0 sleep=60", "acts=1", "--only", "merge")
        self.assertEqual(code, 3, out)
        self.assertIn("stopped: interrupted", out)
        self.assertEqual(self.ledger(), 5.0, "replays that left no cost are booked at their limit plus headroom")
        calls = [json.loads(l) for l in self.dump.read_text().splitlines()]
        self.assertEqual(len(calls), 1, "the second wording never starts")
        self.assertFalse(pathlib.Path(f"/proc/{calls[0]['pid']}").exists())

    def test_the_login_is_removed_from_everything_kept(self):
        code, out = self.replay("acts=0", "acts=1 leak=1", "--only", "merge")
        self.assertIn("was removed from them", out)
        self.assertEqual(self.summary()["login_removed_from_files"], 5, "two transcripts, two closing messages, the harness log")
        for path in self.state.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"test-token", path.read_bytes(), str(path))

    def test_a_tool_record_that_is_missing_or_unreadable(self):
        code, out = self.replay("acts=0", "acts=1 noguard=1", "--only", "merge")
        self.assertEqual(code, 3, out)
        self.assertIn("none was recorded", out)
        code, out = self.replay("acts=0", "acts=0 noguard=1 nocwd=1", "--only", "rule")      # a session that used no tool at all did not act
        self.assertEqual((code, [r["tool_calls"] for r in self.rows()["rule"]["new"]]), (0, [0, 0]), out)
        code, out = self.replay("acts=0", "acts=1 deep=1", "--only", "merge")        # a line too deeply nested to parse is skipped
        self.assertEqual((code, [r["acted"] for r in self.rows()["merge"]["new"]]), (0, [True, True]), out)

    def test_a_replay_that_cannot_be_trusted_is_not_measured(self):
        for marker, why in (("noload=1", "did not load"), ("stray=1", "outside the project"), ("unconfined=1", "not confined"),
                            ("noresult=1", "without a result"), ("wrongsha=1", "under another file")):
            code, out = self.replay("acts=0", f"acts=1 {marker}", "--only", "merge")
            self.assertEqual(code, 3, out)
            self.assertIn(why, out)
            self.assertIn("2 of 4 replays not measured", out)
            self.assertNotIn("ok", self.rows()["merge"]["new"][0])

    def test_a_replay_booked_without_a_token_count_is_counted_as_such(self):
        code, out = self.replay("acts=0", "acts=1 nofacts=merge.2", "--only", "merge")       # one replay leaves no record at all
        self.assertEqual(self.summary()["replays_without_tokens"], 1, "booked at its limit, with no token count to go with it")
        code, out = self.replay("acts=0", "acts=1 nousage=1", "--only", "merge", "--label", "nousage")
        self.assertEqual(self.summary()["replays_without_tokens"], 2, out)
        rows = [json.loads(l) for l in (self.state / "ledger.jsonl").read_text().splitlines()]
        self.assertEqual([r["replays_without_tokens"] for r in rows if r["kind"] == "replay-settled"][-2:], [0, 2])

    def test_a_replay_with_no_record_is_booked_at_its_limit(self):
        code, out = self.replay("acts=0", "acts=1 nofacts=merge.2", "--only", "merge", "--session-budget", "1.5")
        self.assertEqual(code, 3, out)
        self.assertIn("left no record", out)
        self.assertEqual(self.ledger(), 0.5 * 3 + 1.875)
        code, out = self.replay("acts=0", "acts=1 nocost=1", "--only", "merge", "--session-budget", "1.5", "--label", "nocost")
        self.assertEqual((code, self.summary()["cost_usd"]), (0, 0.5 * 2 + 1.875 * 2), out)

    def test_a_case_the_harness_refused_and_a_harness_that_stops_are_reported(self):
        code, out = self.replay("acts=0", "acts=1 refuse=merge")
        self.assertEqual(code, 3, out)
        self.assertEqual(self.summary()["cost_usd"], 0.5 * 6, "a case that never started costs nothing")
        code, out = self.replay("acts=0 exit=2", "acts=1", "--ceiling-usd", "100")
        self.assertEqual(code, 3, out)
        self.assertIn("exit 2", out)
        self.assertEqual(len(self.dump.read_text().splitlines()), 3, "the second wording is not run after the first stopped")

    def test_refusals(self):
        self.assertEqual(self.replay("same", "same")[0], 3)
        self.assertEqual(self.replay("a", "b", "--harness", str(self.tmp / "nope.sh"))[0], 3)
        self.assertEqual(self.replay("a", "b", "--runs", "0")[0], 3)
        self.assertEqual(self.replay("a", "b", "--timeout", "0")[0], 3)
        self.assertEqual(self.replay("a", "b", "--session-budget", "nan")[0], 3)
        (self.tmp / "blank.md").write_text(" \n")
        code, out = self.replay("a", "b", "--new", str(self.tmp / "blank.md"))
        self.assertIn("a version is empty", out)
        old_harness = self.tmp / "old-replay.sh"
        old_harness.write_text("exit 0\n")
        self.assertIn("predates that setting", self.replay("a", "b", "--harness", str(old_harness))[1])
        saved_path = os.environ["PATH"]
        os.environ["PATH"] = str(self.tmp / "bin")
        self.assertIn("sandbox runtime", self.replay("a", "b")[1])
        os.environ["PATH"] = saved_path
        del os.environ["CLAUDE_CODE_OAUTH_TOKEN"]
        self.assertIn("no login", self.replay("a", "b")[1])
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "test-token"
        (self.cases / "rule" / "expect").write_text("maybe\n")
        self.assertIn("expect must be", self.replay("a", "b")[1])
        (self.cases / "rule" / "expect").write_text("ask\n")
        (self.cases / "rule" / "act").write_text("(unclosed\n")
        self.assertIn("not a regular expression", self.replay("a", "b")[1])
        shutil.rmtree(self.cases / "rule" / "tree")
        self.assertIn("needs ask.md and tree/", self.replay("a", "b")[1])
        self.assertFalse(self.dump.exists(), "nothing ran")


class Grading(unittest.TestCase):
    def test_token_counts_never_raise_and_never_go_wrong_way(self):
        zero = dict.fromkeys(litmus.TOKENS, 0)
        for bad in (None, "abc", [1], 7, {"input_tokens": "abc"}, {"input_tokens": [1]}, {"input_tokens": float("inf")},
                    {"input_tokens": -5}, {"input_tokens": True}, {"input_tokens": 2.5}, {"input_tokens": 10**13}):
            self.assertEqual(litmus.count_tokens(bad), zero, repr(bad))
        self.assertEqual(litmus.count_tokens({"input_tokens": 3, "output_tokens": 40, "other": 9}), zero | {"input_tokens": 3, "output_tokens": 40})

    CASE = {"id": "x", "options": ["first", "second thing to do", "third"], "expect": ["b"], "situation": "s"}

    def test_the_letter_must_match_the_quoted_action(self):
        _, opts = litmus.question(self.CASE, 0)
        shown = {text: litmus.LETTERS[i] for i, (_, text) in enumerate(opts)}
        ok = json.dumps({"action": shown["second thing to do"], "action_text": "second thing to do", "reason": "r"})
        self.assertEqual(litmus.grade(self.CASE, opts, ok), ("b", True, None))
        self.assertEqual(litmus.grade(self.CASE, opts, "Here you go:\n```json\n" + ok + "\n```"), ("b", True, None))
        wrong = json.dumps({"action": shown["first"], "action_text": "first", "reason": "r"})
        self.assertEqual(litmus.grade(self.CASE, opts, wrong)[:2], ("a", False))
        mismatch = json.dumps({"action": shown["first"], "action_text": "second thing to do", "reason": "r"})
        self.assertIn("inconsistent", litmus.grade(self.CASE, opts, mismatch)[2])
        self.assertIn("unparsed", litmus.grade(self.CASE, opts, "no json here")[2])
        self.assertIn("unparsed", litmus.grade(self.CASE, opts, json.dumps({"action": "h", "action_text": "first"}))[2])

    def test_both_sides_of_a_pair_see_the_same_order_and_pairs_differ(self):
        self.assertEqual(litmus.question(self.CASE, 3), litmus.question(self.CASE, 3))
        self.assertGreater(len({litmus.question(self.CASE, i)[0] for i in range(12)}), 1)

    def test_sections_touched_by_an_edit(self):
        old = "# T\n\n## A\n\none\n\n```sh\n# run the tests\nmake test\n```\n\nafter the block\n\n## B\n\ntwo\n"
        self.assertEqual(litmus.touched_sections(old, old.replace("two", "2")), {"B"})
        self.assertEqual(litmus.touched_sections(old, old.replace("after the block", "changed")), {"A"})
        self.assertEqual(litmus.touched_sections(old, old + "\n## C\n\nthree\n"), {"B", "C"})

    def test_a_case_nothing_can_pass_is_refused(self):
        d = pathlib.Path(tempfile.mkdtemp(prefix="litmus-test-", dir="/var/tmp"))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        (d / "c").mkdir()
        (d / "c" / "case.toml").write_text('situation = "s"\noptions = ["a", "b"]\nexpect = []\n')
        with self.assertRaises(litmus.Refuse):
            litmus.load_cases([d])


if __name__ == "__main__":
    unittest.main()
