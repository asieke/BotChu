"""Protect the shared gate, failed-test selection, and shared pass receipts."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("busy", ROOT / "scripts/coord/busy.py")
busy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(busy)


class WorkflowTests(unittest.TestCase):
    def test_only_explicit_windowless_ancestry_is_exempt(self):
        snapshot = """1 0 launchd launchd
2 1 bash bash /repo/BotChu/scripts/coord/botchu-windowless.sh scripts/test.sh --fast
3 2 bash bash scripts/test.sh --fast
4 3 swift-test swift-test --filter BotChuCoreTests
5 4 swiftpm-testing-helper swiftpm-testing-helper --filter BotChuCoreTests
6 1 swift-test swift-test --filter BotChuRenderingTests
7 6 swiftpm-testing-helper swiftpm-testing-helper --filter BotChuRenderingTests
8 2 bash bash /repo/BotChu/macOS/test.sh --windows
9 8 swift-test swift-test --skip-build --filter BotChuRenderingTests
10 1 bash bash /repo/GitChu/scripts/check.sh --report
11 10 xctest xctest GitChuPackageTests
12 1 bash bash /repo/mono-ios/test.sh
13 1 bash bash /repo/mono-mac/verify-pr.sh
14 1 bash bash /repo/garcon/scripts/test.sh
15 1 bash bash /repo/humanist-tools/scripts/check.sh
16 1 python3 python3 agent.py 'swift-test scripts/test.sh'
17 1 BotChuPackageTests BotChuPackageTests
"""
        self.assertEqual([int(line.split()[0]) for line in busy.busy_lines(snapshot)], [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17])

    def test_failed_test_command_keeps_build_and_only_failed_selection(self):
        with tempfile.TemporaryDirectory() as temporary:
            xml = Path(temporary) / "core.xml"
            xml.with_name("core-swift-testing.xml").write_text('''<testsuites><testsuite>
              <testcase classname="BotChuCoreTests.Example" name="works()" time="0.1"/>
              <testcase classname="BotChuCoreTests.Example" name="fails(value:)" time="2"><failure/></testcase>
              </testsuite></testsuites>''')
            Path(str(xml) + ".command.json").write_text(json.dumps(["swift", "test", "--skip-build", "--configuration", "release", "--scratch-path", "/tmp/build", "--filter", "BotChuCoreTests", "--skip", "OldTests"]))
            output = subprocess.check_output(["python3", str(ROOT / "scripts/test-report.py"), "--failed", str(xml)], text=True)
            self.assertIn("--configuration release --scratch-path /tmp/build", output)
            self.assertIn(r"BotChuCoreTests\.Example/fails\(value:\)", output)
            self.assertNotIn("OldTests", output)
            self.assertNotIn("works", output)

    def test_clean_tree_pass_survives_a_different_commit_but_dirty_work_does_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=folder, text=True, stderr=subprocess.DEVNULL).strip()
            def shell(command):
                return subprocess.run(["bash", "-c", f'source "{ROOT}/scripts/test-passes.sh"; {command}'], cwd=folder, capture_output=True, text=True)
            git("init", "-q")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            (folder / "source").write_text("one")
            git("add", ".")
            git("commit", "-qm", "initial")
            self.assertNotEqual(shell("test_tree_passed").returncode, 0)
            self.assertEqual(shell("test_capture_tree; test_record_pass; test_tree_passed").returncode, 0)
            receipts = folder / ".git/test-passes"
            self.assertEqual(len(receipts.read_text().splitlines()), 1)
            git("commit", "--allow-empty", "-qm", "same tree")
            self.assertEqual(shell("test_tree_passed").returncode, 0)
            (folder / "source").write_text("two")
            shell("test_capture_tree; test_record_pass")
            self.assertEqual(len(receipts.read_text().splitlines()), 1)
            git("add", ".")
            git("commit", "-qm", "different tree")
            self.assertNotEqual(shell("test_tree_passed").returncode, 0)
            shell("test_capture_tree; printf changed > source; test_record_pass")
            self.assertEqual(len(receipts.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
