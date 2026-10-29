"""Protect the shared gate, failed-test selection, changed-test selection and shared pass receipts."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("busy", ROOT / "scripts/coord/busy.py")
busy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(busy)
spec = importlib.util.spec_from_file_location("select", ROOT / "scripts/test-select.py")
select = importlib.util.module_from_spec(spec)
spec.loader.exec_module(select)

APP = "macOS/Sources/BotChu/"
CORE = "macOS/Sources/BotChuCore/"
TESTS = "macOS/Tests/BotChuRenderingTests/"
SOURCES = {
    APP + "Sidebar.swift": """struct SidebarView: View {
    let model: AppModel
    var body: some View { BotRow(title: model.title) }
}

struct BotRow: View {
    let title: String
    var body: some View {
        // A row's dots.
        Text(title)
    }
}
""",
    APP + "AppModel.swift": """final class AppModel {
    var title = ""
    func send(_ text: String) { launchTurn(text) }
    func launchTurn(_ text: String) { Store.save(text) }
}
""",
    CORE + "Store.swift": """public enum Store {
    public static func save(_ text: String) { Codec.encode(text) }
}

enum Codec {
    static func encode(_ text: String) {}
}
""",
    TESTS + "SidebarTests.swift": """extension RenderingTests {
    @Test func sidebarShowsRows() {
        let view = SidebarView(model: AppModel())
    }

    @Test func storeSaves() {
        Store.save("x")
    }
}
""",
}
HUB_TESTS = "extension RenderingTests {\n" + "".join(
    f"    @Test func sends{n}() {{\n        AppModel().send(\"{n}\")\n    }}\n" for n in range(select.HUB + 1)) + "}\n"


def choose(changes, new, old=None, diffs=None):
    """Runs the selector on files in memory: new and old map paths to their text."""
    old = SOURCES | {TESTS + "HubTests.swift": HUB_TESTS} if old is None else old
    files = {path: select.parse(path, text) for path, text in new.items()}
    return select.select(changes, files, lambda p: old.get(p, ""), lambda p: new.get(p, ""),
                         lambda p: (diffs or {}).get(p, ""))


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

    def test_legacy_gate_ancestor_is_detected_without_a_marker(self):
        snapshot = """1 0 launchd launchd
2 1 bash /bin/bash /tmp/botchu-coord/gate.sh _run 1234
3 2 bash bash scripts/test.sh
4 3 python3 python3 busy.py --in-gate
5 1 zsh zsh -c 'mention gate.sh _run in a message'
6 5 python3 python3 busy.py --in-gate
"""
        self.assertTrue(busy.in_gate(snapshot, 4))
        self.assertFalse(busy.in_gate(snapshot, 6))
        with tempfile.TemporaryDirectory() as temporary:
            gate = Path(temporary) / "gate.sh"
            gate.write_text('#!/bin/bash\nshift\n"$@"\n')
            environment = dict(os.environ)
            environment.pop("BOTCHU_GATE_RUN_ID", None)
            check = f'test_root="{ROOT}"; source "{ROOT}/scripts/test-support.sh"; test_inside_gate'
            self.assertEqual(subprocess.run(["bash", str(gate), "_run", "bash", "-c", check], env=environment).returncode, 0)
            self.assertEqual(subprocess.run(["bash", "-c", check], env=environment).returncode, 1)

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

    def test_a_view_change_runs_the_tests_hosting_the_view_that_shows_it(self):
        new = SOURCES | {TESTS + "HubTests.swift": HUB_TESTS}
        new[APP + "Sidebar.swift"] = new[APP + "Sidebar.swift"].replace("Text(title)", "Text(title).bold()")
        selection, reasons, release = choose([("M", APP + "Sidebar.swift")], new,
                                             diffs={APP + "Sidebar.swift": "@@ -10 +10 @@\n"})
        self.assertEqual(selection, {"sidebarShowsRows"})
        self.assertFalse(release)
        self.assertIn("BotRow -> SidebarView -> 1 tests", reasons[-1])

    def test_comments_and_brackets_alone_select_nothing(self):
        new = SOURCES | {TESTS + "HubTests.swift": HUB_TESTS}
        selection, _, _ = choose([("M", APP + "Sidebar.swift")], new,
                                 diffs={APP + "Sidebar.swift": "@@ -9 +9 @@\n@@ -12 +12 @@\n"})
        self.assertEqual(selection, set())

    def test_core_is_left_to_its_own_tests_and_names_most_tests_use_lead_nowhere(self):
        new = SOURCES | {TESTS + "HubTests.swift": HUB_TESTS}
        # Codec reaches the window tests only through Core (Store) and then AppModel.send.
        selection, reasons, _ = choose([("M", CORE + "Store.swift")], new,
                                       diffs={CORE + "Store.swift": "@@ -6 +6 @@\n"})
        self.assertEqual(selection, set())
        self.assertIn("no window test uses it", reasons[-1])
        selection, reasons, _ = choose([("M", APP + "AppModel.swift")], new,
                                       diffs={APP + "AppModel.swift": "@@ -4 +4 @@\n"})
        self.assertEqual(selection, set())
        self.assertIn("reaches only names most window tests use", reasons[-1])
        # A Core declaration that window tests name directly still selects them.
        selection, _, _ = choose([("M", CORE + "Store.swift")], new,
                                 diffs={CORE + "Store.swift": "@@ -2 +2 @@\n"})
        self.assertEqual(selection, {"storeSaves"})

    def test_changed_tests_run_but_deleted_ones_do_not_and_infrastructure_runs_everything(self):
        new = SOURCES | {TESTS + "HubTests.swift": HUB_TESTS}
        old = dict(new)
        new[TESTS + "SidebarTests.swift"] = new[TESTS + "SidebarTests.swift"].replace(
            '        Store.save("x")\n', '        Store.save("y")\n')
        old[TESTS + "Gone.swift"] = "extension RenderingTests {\n    @Test func gone() {}\n}\n"
        selection, _, _ = choose([("M", TESTS + "SidebarTests.swift"), ("D", TESTS + "Gone.swift")], new, old,
                                 {TESTS + "SidebarTests.swift": "@@ -7 +7 @@\n"})
        self.assertEqual(selection, {"storeSaves"})
        for path in ("macOS/Package.swift", "scripts/coord/gate.sh", APP + "Resources/ChatRenderer/chat.js"):
            self.assertEqual(choose([("M", path)], new)[0], "all")
        self.assertEqual(choose([("M", "README.md"), ("A", "macOS/Tests/BotChuCoreTests/New.swift")], new)[0], set())

    def test_a_shared_member_name_is_traced_by_whichever_of_it_and_its_type_is_rarer(self):
        source = """struct Bot {
    var fastMode: Bool
}

struct Job {
    var fastMode: Bool
}
"""
        tests = "extension RenderingTests {\n    @Test func fast() {\n        _ = bot.fastMode\n    }\n" + "".join(
            f"    @Test func bot{n}() {{\n        _ = Bot()\n    }}\n" for n in range(3)) + "}\n"
        new = {CORE + "Models.swift": source, TESTS + "BotTests.swift": tests}
        selection, _, _ = choose([("M", CORE + "Models.swift")], new, new, {CORE + "Models.swift": "@@ -2 +2 @@\n"})
        self.assertEqual(selection, {"fast"})

    def test_sensitive_input_requires_release_without_a_task_group(self):
        path = CORE + "SensitiveInput.swift"
        source = "public enum SensitiveInputDestination {\n    public static func validate() {}\n}"
        _, reasons, release = choose([("A", path)], {path: source})
        self.assertTrue(release)
        self.assertTrue(any("optimized validation" in reason for reason in reasons))

    def test_new_files_and_task_groups(self):
        new = SOURCES | {TESTS + "HubTests.swift": HUB_TESTS}
        new[APP + "Extra.swift"] = """extension AppModel {
    func refresh() async {
        await withTaskGroup(of: Void.self) { _ in }
    }
}
"""
        new[APP + "Sidebar.swift"] = new[APP + "Sidebar.swift"].replace(
            "BotRow(title: model.title)", "BotRow(title: model.title).task { await model.refresh() }")
        selection, reasons, release = choose([("A", APP + "Extra.swift"), ("M", APP + "Sidebar.swift")], new,
                                             diffs={APP + "Sidebar.swift": "@@ -3 +3 @@\n"})
        self.assertTrue(release)
        self.assertEqual(selection, {"sidebarShowsRows"})
        self.assertFalse(any(": AppModel" in reason for reason in reasons))
        self.assertEqual(select.report(selection, release, "sidebarShowsRows"), ["none", "alone", "release"])
        self.assertEqual(select.report("all", False, "x"), ["all", "alone"])
        self.assertEqual(select.report({"a", "b"}, False, "x"),
                         [r"BotChuRenderingTests\.RenderingTests/(a|b)\("])

    def test_selection_reads_the_working_tree_against_its_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=folder, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            for path, text in SOURCES.items():
                (folder / path).parent.mkdir(parents=True, exist_ok=True)
                (folder / path).write_text(text)
            git("add", ".")
            git("commit", "-qm", "initial")
            def run():
                return subprocess.check_output(["python3", str(ROOT / "scripts/test-select.py"), "--base", "HEAD"],
                                               cwd=folder, text=True).splitlines()
            self.assertEqual(run(), ["none"])
            sidebar = folder / APP / "Sidebar.swift"
            sidebar.write_text(sidebar.read_text().replace("Text(title)", "Text(title).bold()"))
            self.assertEqual(run(), [r"BotChuRenderingTests\.RenderingTests/(sidebarShowsRows)\("])
            git("checkout", "--", ".")
            (folder / TESTS / "NewTests.swift").write_text(
                "extension RenderingTests {\n    @Test func brandNew() {}\n}\n")
            self.assertEqual(run(), [r"BotChuRenderingTests\.RenderingTests/(brandNew)\("])

    def test_gate_install_restores_missing_files_without_touching_live_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            lock = folder / "gate/lock"
            lock.mkdir(parents=True)
            (lock / "run").write_text("existing-run")
            install = ["bash", str(ROOT / "scripts/coord/install.sh"), str(folder)]
            subprocess.run(install, check=True)
            self.assertEqual((folder / "busy.py").read_bytes(), (ROOT / "scripts/coord/busy.py").read_bytes())
            first = (folder / "gate.sh").stat().st_mtime_ns
            subprocess.run(install, check=True)
            self.assertEqual((folder / "gate.sh").stat().st_mtime_ns, first)
            self.assertEqual((lock / "run").read_text(), "existing-run")
            (folder / "busy.sh").unlink()
            subprocess.run(install, check=True)
            self.assertTrue((folder / "busy.sh").exists())

    def test_deploy_reuses_tree_pass_and_honors_both_explicit_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "scripts").mkdir()
            (folder / "macOS").mkdir()
            for name in ("deploy.sh", "test-passes.sh"):
                shutil.copy2(ROOT / "scripts" / name, folder / "scripts" / name)
            for name, marker in (("scripts/test.sh", "full-tests"), ("macOS/install.sh", "installs")):
                path = folder / name
                path.write_text(f"#!/bin/bash\nprintf 'run\\n' >> .git/{marker}\n")
                path.chmod(0o755)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=folder, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-qb", "main")
            git("config", "user.name", "Test")
            git("config", "user.email", "test@example.invalid")
            git("add", ".")
            git("commit", "-qm", "fixture")
            env = dict(os.environ, DEPLOY_UPDATED="1", DEPLOY_FROM=git("rev-parse", "HEAD"))
            def deploy(*args):
                return subprocess.check_output(["bash", "scripts/deploy.sh", *args], cwd=folder, env=env, text=True)
            self.assertIn("running full tests", deploy())
            receipts = folder / ".git/test-passes"
            receipts.write_text(f"{git('rev-parse', 'HEAD^{tree}')} {git('rev-parse', 'HEAD')} 2026-01-01T00:00:00Z\n")
            self.assertIn("already passed", deploy())
            self.assertIn("running full tests", deploy("--tests"))
            self.assertIn("--skip-tests", deploy("--skip-tests"))
            self.assertEqual((folder / ".git/full-tests").read_text().splitlines(), ["run", "run"])
            self.assertEqual(len((folder / ".git/installs").read_text().splitlines()), 4)
            for receipt in (folder / ".git/deploys").read_text().splitlines():
                _, commit, state = receipt.split()
                self.assertEqual(commit, git("rev-parse", "HEAD"))
                self.assertEqual(state, "ok")


if __name__ == "__main__":
    unittest.main()
