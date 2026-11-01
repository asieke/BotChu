"""The replica the replica journeys run on (#422): what it copies, what it rewrites, and that the live data stays as it was."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOT, SPECIALIST, AREA, TASK, DELIVERY, JOB = (f"00000000-0000-4000-8422-00000000000{n}" for n in range(1, 7))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value, str) else json.dumps(value))


def checksums(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "dir"
            for p in sorted(folder.rglob("*"))}


class ReplicaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name).resolve()
        self.live = self.home / "Library/Application Support/BotChu"
        self.replica = self.home / "Library/Application Support/BotChu Replica"
        one, two = self.home / "Desktop/BOTS/Engineer Bot", self.home / "Desktop/BOTS/Helper"
        checkout = self.home / "Desktop/WORKSPACE/BotChu"
        write(self.live / "index.json", [{"id": BOT, "workspace": str(one)}, {"id": SPECIALIST, "workspace": str(two), "role": "specialist"}])
        write(self.live / "inbox.json", {"entries": {DELIVERY: {"read": True, "done": False}}})
        write(self.live / "usage.json", [{"accountID": "claude-work", "botToken": "secret-value", "inputTokens": 12}])
        write(self.live / "telegram.json", {"botUserID": 1})
        write(self.live / "projects.json", {"login": "owner"})
        write(one / "INSTRUCTIONS.md", "private")
        botchu = one / ".botchu"
        write(botchu / "bot.json", {"id": BOT, "name": "Engineer", "workspace": str(one), "accountID": "claude-work",
                                    "sessionAccountID": "claude-work", "sessionID": "s", "providerID": "p",
                                    "accountProfile": {"defaultCommand": "/opt/homebrew/bin/claude"}})
        write(botchu / f"tasks/{AREA}/task.json", {"id": AREA, "repo": "o/BotChu", "checkout": str(checkout), "folder": str(checkout),
                                                   "area": {"kind": "repo"}, "accountID": "codex-work"})
        write(botchu / f"tasks/{AREA}/thread.jsonl", "{}\n")
        write(botchu / f"tasks/{AREA}/queued.jsonl", "{}\n")
        write(botchu / f"tasks/{TASK}/task.json", {"id": TASK, "repo": "o/BotChu", "checkout": str(checkout),
                                                   "folder": str(checkout / ".claude/worktrees/feat-x"), "accountID": "codex-work",
                                                   "requestedBy": {"key": "k", "name": "Fox"}})
        write(botchu / f"inbox/{DELIVERY}/delivery.json", {"id": DELIVERY, "botID": BOT, "title": "Done",
                                                           "files": [{"source": str(self.home / "Downloads/report.md")}]})
        write(botchu / f"jobs/{JOB}/job.json", {"id": JOB, "enabled": True, "accountID": "claude-work"})
        for skipped in ("logs/today.log", "deployments/a/b.txt", "dispatch/task.json", "usage/2026-10.jsonl", "evaluations/x/e.json"):
            write(botchu / skipped, "x")
        write(two / ".botchu/bot.json", {"id": SPECIALIST, "name": "Helper", "workspace": str(two), "role": "specialist", "accountID": "pi"})
        self.before = {"live": checksums(self.live), "one": checksums(one), "two": checksums(two)}
        self.one, self.two = one, two

    def tearDown(self):
        for path in self.home.rglob("*"):
            if path.is_dir():
                path.chmod(0o755)
        self.temp.cleanup()

    def run_script(self, *args):
        env = dict(os.environ, HOME=str(self.home))
        env.pop("BOTCHU_REPLICA", None)
        env.pop("BOTCHU_REPLICA_LIVE", None)
        return subprocess.run([str(ROOT / "scripts/replica.sh"), *args], env=env, capture_output=True, text=True, check=True).stdout

    def test_status_without_a_replica(self):
        self.assertIn("no replica: run scripts/replica.sh refresh", self.run_script("status"))

    def test_refresh_copies_only_botchus_data_and_rewrites_it(self):
        out = self.run_script("refresh")
        self.assertNotIn("Engineer", out)
        self.assertEqual(self.before, {"live": checksums(self.live), "one": checksums(self.one), "two": checksums(self.two)})
        r = self.replica
        index = json.loads((r / "index.json").read_text())
        self.assertEqual([e["workspace"] for e in index], [str(r / "bots/engineer-bot"), str(r / "bots/helper")])
        self.assertFalse((r / "telegram.json").exists() or (r / "projects.json").exists())
        bots = r / "bots/engineer-bot"
        self.assertFalse((bots / "INSTRUCTIONS.md").exists())
        for skipped in ("logs", "deployments", "dispatch", "usage", "evaluations", f"tasks/{AREA}/queued.jsonl"):
            self.assertFalse((bots / ".botchu" / skipped).exists(), skipped)
        self.assertTrue((bots / f".botchu/tasks/{AREA}/thread.jsonl").exists())
        bot = json.loads((bots / ".botchu/bot.json").read_text())
        self.assertEqual((bot["workspace"], bot["accountID"], bot["sessionAccountID"]), (str(bots), "custom-review-0", "custom-review-0"))
        self.assertNotIn("accountProfile", bot)
        self.assertNotIn("providerID", bot)
        usage = json.loads((r / "usage.json").read_text())
        self.assertEqual(usage, [{"accountID": "custom-review-0", "inputTokens": 12}])
        self.assertFalse(json.loads((bots / f".botchu/jobs/{JOB}/job.json").read_text())["enabled"])
        area = json.loads((bots / f".botchu/tasks/{AREA}/task.json").read_text())
        task = json.loads((bots / f".botchu/tasks/{TASK}/task.json").read_text())
        stub = Path(area["checkout"])
        self.assertTrue(stub.is_relative_to(r / "repos"))
        self.assertEqual((area["folder"], task["checkout"]), (str(stub), str(stub)))
        self.assertEqual(list(stub.iterdir()), [])
        self.assertEqual(stub.stat().st_mode & 0o777, 0o555)
        self.assertEqual(task["folder"], str(stub / ".claude/worktrees/feat-x"))
        self.assertFalse(Path(task["folder"]).exists())
        # No path in the replica leads out of it into the home folder.
        for file in r.rglob("*.json"):
            text = file.read_text()
            for line in text.split(str(self.home))[1:]:
                self.assertTrue(line.startswith("/Library/Application Support/BotChu Replica"), f"{file}: {line[:60]}")
        info = json.loads((r / "replica.json").read_text())
        self.assertEqual({k: info["totals"][k] for k in ("bots", "principal", "areas", "tasks", "deliveries", "runs")},
                         {"bots": 2, "principal": 1, "areas": 1, "tasks": 1, "deliveries": 1, "runs": 0})
        self.assertIn("2 bots", self.run_script("status"))
        # Refreshing again replaces it, read-only stubs and all.
        self.run_script("refresh")
        self.assertTrue((r / "replica.json").exists())
        self.assertFalse(r.with_name(r.name + ".old").exists())


if __name__ == "__main__":
    unittest.main()
