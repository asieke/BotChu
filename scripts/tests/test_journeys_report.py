"""The journeys latency report (#362): its comparison, its bytes, and deploy's delivery, offline and without the app."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("journeys_report", ROOT / "scripts/journeys-report.py")
journeys_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journeys_report)


def run(at, commit, medians, failed=(), ratcheted=(), branch="main"):
    """A results file's contents, as `botchu-journeys --results` writes them."""
    steps = []
    for key, value in medians.items():
        journey, name = key.split(" ", 1)
        steps.append({"journey": int(journey), "step": name, "key": key, "budget": 16.0, "tier": "Instant",
                      "limit": 48.5 if key in ratcheted else 16.0, "ratcheted": key in ratcheted, "median": value,
                      "p95": value, "samples": [value], "passed": key not in failed,
                      **({"failure": f"median {value} ms over its budget"} if key in failed else {})})
    return {"recordedAt": at, "commit": commit, "branch": branch, "machine": "Mac16,5, 14 cores", "hertz": 120,
            "loadBefore": [5.03, 6.6, 6.03], "loadAfter": [4.19, 5.58, 5.7], "seconds": 312,
            "medians": {key: value for key, value in medians.items() if value is not None}, "steps": steps}


def paths_without_inbox():
    """PATH without any real botchu-inbox, so a test never delivers to the owner."""
    return [entry for entry in os.environ["PATH"].split(os.pathsep) if entry and not (Path(entry) / "botchu-inbox").exists()]


class JourneysReportTests(unittest.TestCase):
    def test_each_step_is_judged_against_the_median_of_its_three_newest_earlier_runs_on_main(self):
        steps = ["2 sidebar · open", "3 switch bot", "4 switch task", "5 echo", "6 message shows", "7 Jump to Latest"]
        this = run("2026-10-30T12:00:00Z", "fff0000", dict(zip(steps, [20.0, 50.0, 10.0, 30.0, 12.0, 47.0])),
                   failed={"6 message shows"}, ratcheted={"7 Jump to Latest"}, branch="feat/x")
        history = [
            (Path("a"), run("2026-10-30T08:00:00Z", "aaa0000", dict(zip(steps, [100.0] * 6)))),
            (Path("b"), run("2026-10-30T09:00:00Z", "bbb0000", dict(zip(steps, [10.0, 30.0, 40.0, 30.0, 12.0, 45.0])))),
            (Path("c"), run("2026-10-30T10:00:00Z", "ccc0000", dict(zip(steps, [12.0, 34.0, 42.0, 31.0, 12.0, 46.0])))),
            (Path("d"), run("2026-10-30T11:00:00Z", "ddd0000", {"2 sidebar · open": 14.0, "3 switch bot": 38.0})),
            # Not prior: a branch's commit, this very commit, and a run recorded after this one.
            (Path("e"), run("2026-10-30T11:30:00Z", "eee0000-dirty", dict(zip(steps, [1.0] * 6)))),
            (Path("f"), run("2026-10-30T11:40:00Z", "fff0000", dict(zip(steps, [1.0] * 6)))),
            (Path("g"), run("2026-10-30T13:00:00Z", "ggg0000", dict(zip(steps, [1.0] * 6)))),
        ]
        prior = journeys_report.prior_runs(history, this, lambda commit: not commit.endswith("-dirty"))
        self.assertEqual([found["commit"] for found in prior], ["ddd0000", "ccc0000", "bbb0000", "aaa0000"])
        rows = {row["step"]["key"]: row for row in journeys_report.compare(this, {"medians": {"2 sidebar · open": 11.0}}, prior)}
        # 2 and 3 take d, c and b; 4–7 aren't in d, so they reach back to a.
        self.assertEqual({key: row["prior"] for key, row in rows.items()},
                         {"2 sidebar · open": 12.0, "3 switch bot": 34.0, "4 switch task": 42.0, "5 echo": 31.0,
                          "6 message shows": 12.0, "7 Jump to Latest": 46.0})
        self.assertAlmostEqual(rows["2 sidebar · open"]["delta"], 66.666, places=2)
        self.assertEqual({key: row["verdict"] for key, row in rows.items()},
                         {"2 sidebar · open": "slower", "3 switch bot": "slower", "4 switch task": "faster", "5 echo": "ok",
                          "6 message shows": "FAILED", "7 Jump to Latest": "ratcheted"})
        self.assertEqual(rows["2 sidebar · open"]["baseline"], 11.0)
        self.assertEqual([row["step"]["key"] for row in journeys_report.compare(this, {}, prior)],
                         ["6 message shows", "2 sidebar · open", "3 switch bot", "7 Jump to Latest", "4 switch task", "5 echo"])
        # Within 25 % or within 3 ms of the prior median is ok, either way.
        step = {"passed": True, "median": 13.0}
        self.assertEqual(journeys_report.verdict(step, 10.5), "ok")
        self.assertEqual(journeys_report.verdict({"passed": True, "median": 100.0}, 124.0), "ok")
        self.assertEqual(journeys_report.verdict({"passed": True, "median": 100.0}, 134.0), "faster")
        text = journeys_report.report(this, {"commit": "d6c373c", "medians": {}}, history, lambda commit: not commit.endswith("-dirty"))
        self.assertTrue(text.startswith("Latency report for BotChu fff0000 on feat/x: 5 of 6 journey steps passed; "
                                        "1 FAILED, 2 slower, 1 faster and 1 ratcheted against the median of up to 3 prior runs on main. "
                                        "Load 5.03 → 4.19.\n"))
        self.assertIn("prior runs on main: ddd0000, ccc0000, bbb0000\n", text)
        self.assertIn("| 6 message shows | 16.0 | — | 12.0 | 12.0 | +0 % | FAILED |\n", text)
        self.assertIn("| 7 Jump to Latest | 16.0 → 48.5 | — | 46.0 | 47.0 | +2 % | ratcheted |\n", text)
        self.assertIn("| 4 switch task | 16.0 | — | 42.0 | 10.0 | -76 % | faster |\n", text)
        self.assertIn("- 6 message shows: median 12.0 ms over its budget\n", text)
        words = len(text.splitlines()[0].split())
        self.assertTrue(25 <= words <= 50, words)

    def test_without_history_the_prior_columns_are_dashes(self):
        this = run("2026-10-30T12:00:00Z", "fff0000", {"1 launch": 640.0, "13 relaunch": None}, failed={"13 relaunch"})
        this["steps"][1]["failure"] = "BotChu isn't running"
        text = journeys_report.report(this, {"commit": "d6c373c", "medians": {"1 launch": 653.4}}, [], lambda commit: True)
        self.assertEqual(text.splitlines()[0], "Latency report for BotChu fff0000 on main: 1 of 2 journey steps passed; 1 FAILED and 0 ratcheted; "
                                               "no prior runs on main to compare with yet. Load 5.03 → 4.19.")
        self.assertIn("prior runs on main: —\n", text)
        self.assertIn("| 13 relaunch | 16.0 | — | — | — | — | FAILED |\n", text)
        self.assertIn("| 1 launch | 16.0 | 653.4 | — | 640.0 | — | ok |\n", text)
        self.assertTrue(25 <= len(text.splitlines()[0].split()) <= 50)

    def fixture(self, folder):
        """A repository with the report, deploy's step and a baseline, two commits on origin/main and a stub journeys run."""
        for name in ("journeys-report.py", "deploy-report.sh"):
            (folder / "scripts").mkdir(exist_ok=True)
            shutil.copy2(ROOT / "scripts" / name, folder / "scripts" / name)
        (folder / "macOS/Journeys").mkdir(parents=True)
        (folder / "macOS/Journeys/baseline.json").write_text(json.dumps({"commit": "d6c373c", "medians": {"2 sidebar · open": 30.0}}))
        test = folder / "scripts/test.sh"
        test.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> .git/journeys\n'
                        'mkdir -p "$BOTCHU_JOURNEYS_RUNS"\n'
                        'commit=$(git rev-parse --short=7 HEAD)\n'
                        'sed "s/COMMIT/$commit/" .git/run.json > "$BOTCHU_JOURNEYS_RUNS/20261030T120000Z-$commit.json"\n'
                        'exit 1\n')
        test.chmod(0o755)
        def git(*args):
            return subprocess.check_output(["git", *args], cwd=folder, text=True, stderr=subprocess.DEVNULL).strip()
        git("init", "-qb", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.invalid")
        git("add", ".")
        git("commit", "-qm", "earlier")
        earlier = git("rev-parse", "--short=7", "HEAD")
        git("commit", "--allow-empty", "-qm", "deployed")
        git("update-ref", "refs/remotes/origin/main", "HEAD")
        (folder / ".git/run.json").write_text(json.dumps(run("2026-10-30T12:00:00Z", "COMMIT", {"2 sidebar · open": 33.0})))
        return earlier, git("rev-parse", "--short=7", "HEAD")

    def test_the_report_is_the_same_bytes_every_time_and_reads_only_runs_on_main(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / "repo"
            folder.mkdir()
            earlier, head = self.fixture(folder)
            runs = Path(temporary) / "runs"
            runs.mkdir()
            (runs / f"20261030T100000Z-{earlier}.json").write_text(json.dumps(run("2026-10-30T10:00:00Z", earlier, {"2 sidebar · open": 20.0})))
            (runs / "20261030T103000Z-1234567.json").write_text(json.dumps(run("2026-10-30T10:30:00Z", "1234567", {"2 sidebar · open": 33.0})))
            (runs / "20261030T104000Z-broken.json").write_text("{")
            (runs / f"20261030T110000Z-{head}.json").write_text(json.dumps(run("2026-10-30T11:00:00Z", head, {"2 sidebar · open": 30.0})))
            env = dict(os.environ, BOTCHU_JOURNEYS_RUNS=str(runs))
            command = ["python3", str(folder / "scripts/journeys-report.py"), "--write", str(Path(temporary) / "report.md")]
            first = subprocess.run(command, cwd=folder, env=env, capture_output=True, check=True)
            second = subprocess.run(command, cwd=Path(temporary), env=env, capture_output=True, check=True)
            self.assertEqual(first.stdout, second.stdout)
            self.assertEqual((Path(temporary) / "report.md").read_bytes(), first.stdout)
            self.assertIn(b"cannot read", first.stderr)
            text = first.stdout.decode()
            # The newest run is reported; 1234567 isn't on origin/main, so only the earlier commit is prior.
            self.assertIn(f"prior runs on main: {earlier}\n", text)
            self.assertIn("| 2 sidebar · open | 16.0 | 30.0 | 20.0 | 30.0 | +50 % | slower |\n", text)

    def deliver(self, folder, runs, inbox):
        """Runs deploy's step with a stub botchu-inbox (when given) first on PATH; returns its output."""
        stubs = folder.parent / "stubs"
        stubs.mkdir(exist_ok=True)
        if inbox is not None:
            stub = stubs / "botchu-inbox"
            stub.write_text(f'#!/bin/bash\nprintf "%s\\0" "$@" >> "{folder.parent}/inbox"\nprintf "\\n" >> "{folder.parent}/inbox"\nexit {inbox}\n')
            stub.chmod(0o755)
        env = dict(os.environ, BOTCHU_JOURNEYS_RUNS=str(runs), PATH=os.pathsep.join([str(stubs), *paths_without_inbox()]))
        return subprocess.run(["bash", "scripts/deploy-report.sh"], cwd=folder, env=env, capture_output=True, text=True, check=True).stdout

    def sends(self, folder):
        inbox = folder.parent / "inbox"
        return [line.split("\0")[:-1] for line in inbox.read_text().splitlines()] if inbox.exists() else []

    def test_deploy_sends_one_fyi_and_runs_the_journeys_only_when_the_commit_has_no_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / "repo"
            folder.mkdir()
            _, head = self.fixture(folder)
            runs = Path(temporary) / "runs"
            runs.mkdir()
            results = runs / f"20261030T110000Z-{head}.json"
            results.write_text(json.dumps(run("2026-10-30T11:00:00Z", head, {"2 sidebar · open": 31.0})))
            output = self.deliver(folder, runs, inbox=0)
            self.assertFalse((folder / ".git/journeys").exists())
            report = runs / f"20261030T110000Z-{head}.md"
            summary = report.read_text().splitlines()[0]
            self.assertTrue(summary.startswith(f"Latency report for BotChu {head} on main: 1 of 1 journey steps passed"))
            self.assertEqual(self.sends(folder), [["send", "--purpose", "fyi", "--title", f"BotChu {head} deployed: latency report",
                                                   "--note", summary, "--file", str(report)]])
            self.assertIn("sent the latency report", output)

            # Without results for the deployed commit, it runs the journeys first, and reports even though they failed.
            results.unlink()
            report.unlink()
            (folder.parent / "inbox").unlink()
            output = self.deliver(folder, runs, inbox=0)
            self.assertEqual((folder / ".git/journeys").read_text(), "--journeys\n")
            self.assertIn("the journeys failed (exit 1)", output)
            report = runs / f"20261030T120000Z-{head}.md"
            self.assertEqual(self.sends(folder), [["send", "--purpose", "fyi", "--title", f"BotChu {head} deployed: latency report",
                                                   "--note", report.read_text().splitlines()[0], "--file", str(report)]])

    def test_without_an_inbox_or_when_it_cannot_send_deploy_prints_the_reports_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / "repo"
            folder.mkdir()
            _, head = self.fixture(folder)
            runs = Path(temporary) / "runs"
            runs.mkdir()
            (runs / f"20261030T110000Z-{head}.json").write_text(json.dumps(run("2026-10-30T11:00:00Z", head, {"2 sidebar · open": 31.0})))
            report = runs / f"20261030T110000Z-{head}.md"
            self.assertIn(f"deploy: latency report {report}\n", self.deliver(folder, runs, inbox=None))
            self.assertIn(f"deploy: latency report {report}\n", self.deliver(folder, runs, inbox=1))
            self.assertEqual(len(self.sends(folder)), 1)
            self.assertFalse((folder / ".git/journeys").exists())


if __name__ == "__main__":
    unittest.main()
