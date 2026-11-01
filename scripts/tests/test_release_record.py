"""The Testing dashboard's release record (#434): what one release keeps, and how a later one is added."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_record", ROOT / "scripts/release-record.py")
release_record = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_record)

# Two commits of this repository's history: the Project Areas batch, from before #410 through #432.
BEFORE, RELEASE = "ffa8561", "d88b4bf"


def results(commit, medians):
    steps = [{"journey": int(key.split(" ", 1)[0]), "step": key.split(" ", 1)[1], "key": key, "budget": 50.0,
              "median": value, "p95": value, "samples": [value], "passed": value <= 50, "tier": "≤ 50 ms"}
             for key, value in medians.items()]
    return {"recordedAt": "2026-11-01T01:53:46Z", "commit": commit, "seconds": 223, "machine": "Mac16,5",
            "loadBefore": [4.25, 5.53, 5.32], "steps": steps, "medians": medians}


class ReleaseRecordTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.data = self.folder / "data"
        patch = mock.patch.dict(os.environ, {"BOTCHU_DATA_DIR": str(self.data), "BOTCHU_JOURNEYS_RUNS": str(self.folder / "runs")})
        patch.start()
        self.addCleanup(patch.stop)
        (self.folder / "runs").mkdir()
        self.releases = self.data / "testing/releases.json"

    def run_for(self, commit, medians, stamp="20261101T015346Z"):
        (self.folder / "runs" / f"{stamp}-{commit}.json").write_text(json.dumps(results(commit, medians)))

    def recorded(self):
        return json.loads(self.releases.read_text())["releases"]

    def test_a_release_keeps_its_journeys_suite_and_the_changelog_lines_since_the_given_commit(self):
        self.run_for(RELEASE, {"3 switch bot": 60.8, "1 launch": 648.5}, stamp="20261101T000000Z")
        self.run_for(RELEASE, {"3 switch bot": 40.0, "1 launch": 600.0})
        suite = self.folder / "steps"
        suite.write_text("core tests\t95\nnot a step\nmacOS tests\t300\ntotal\t812\n")
        release_record.main(["--version", "1.0.0", "--commit", RELEASE, "--since", BEFORE, "--suite", str(suite), "--date", "2026-11-01T01:53:46Z"])

        [release] = self.recorded()
        self.assertEqual((release["version"], release["commit"], release["date"]), ("1.0.0", RELEASE, "2026-11-01T01:53:46Z"))
        self.assertEqual(release["suite"], {"seconds": 812, "steps": [{"step": "core tests", "seconds": 95}, {"step": "macOS tests", "seconds": 300}]})
        self.assertEqual(release["journeys"]["seconds"], 223)
        self.assertEqual([(s["journey"], s["step"], s["median"], s["passed"]) for s in release["journeys"]["steps"]],
                         [(1, "launch", 600.0, False), (3, "switch bot", 40.0, True)], "the newest run of the commit, in journey order")
        self.assertEqual(len(release["changes"]), 14)
        self.assertTrue(release["changes"][0].startswith("Sub-agent details open with a card"))
        self.assertTrue(release["changes"][-1].endswith("(#410)"))
        self.assertEqual(stat.S_IMODE(self.releases.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.releases.parent.stat().st_mode), 0o700)

    def test_the_next_release_starts_after_the_previous_one_and_recording_a_version_again_replaces_it(self):
        release_record.main(["--version", "1.0.0", "--commit", BEFORE, "--since", "a39ec07"])
        release_record.main(["--version", "1.1.0", "--commit", "080862d"])
        release_record.main(["--version", "1.1.0", "--commit", RELEASE])

        old, new = self.recorded()
        self.assertEqual((old["version"], new["version"], new["commit"]), ("1.0.0", "1.1.0", RELEASE))
        self.assertIsNone(new["suite"])
        self.assertIsNone(new["journeys"])
        self.assertEqual(len(new["changes"]), 14, "everything since 1.0.0's commit, not since the replaced entry")


if __name__ == "__main__":
    unittest.main()
