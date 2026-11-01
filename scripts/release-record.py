#!/usr/bin/env python3
"""Records a release in BotChu's Testing dashboard data (#434; README, Operate): its version
(macOS/VERSION), commit, date, the full suite's step timings when it ran, the journeys' medians from
their results file, and the CHANGELOG lines added since the previous release's commit. It writes
testing/releases.json in BotChu's data folder (BOTCHU_DATA_DIR, or ~/Library/Application Support/BotChu),
owner-only; recording a version again replaces its entry. View > Open Testing Dashboard shows the file."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def data_folder():
    custom = os.environ.get("BOTCHU_DATA_DIR")
    return Path(custom) if custom else Path.home() / "Library/Application Support/BotChu"


def newest_results(commit):
    runs = Path(os.environ.get("BOTCHU_JOURNEYS_RUNS") or Path.home() / "Library/Caches/botchu-journeys/runs")
    found = sorted(runs.glob(f"*-{commit}.json"))
    return found[-1] if found else None


def journeys(results):
    """The journeys run as the dashboard shows it: each step's median against its budget."""
    steps = [{"journey": step["journey"], "step": step["step"], "median": round(step["median"], 1),
              "budget": step["budget"], "passed": step["passed"]}
             for step in results.get("steps", []) if step.get("median") is not None]
    steps.sort(key=lambda step: step["journey"])
    return {"recordedAt": results.get("recordedAt"), "seconds": results.get("seconds"),
            "machine": results.get("machine"), "load": results.get("loadBefore"), "steps": steps}


def suite(lines):
    """`label<TAB>seconds` lines in run order, as scripts/test-support.sh writes them to BOTCHU_TEST_STEPS
    and deploy adds its `total`; None when the suite didn't run."""
    steps, total = [], None
    for line in lines:
        label, _, seconds = line.rstrip("\n").rpartition("\t")
        if not label or not seconds.isdigit():
            continue
        if label == "total":
            total = int(seconds)
        else:
            steps.append({"step": label, "seconds": int(seconds)})
    if not steps and total is None:
        return None
    return {"seconds": total if total is not None else sum(step["seconds"] for step in steps), "steps": steps}


def changes(since, commit):
    """The CHANGELOG lines `since..commit` added, in file order (newest first)."""
    diff = git("diff", "--unified=0", f"{since}..{commit}", "--", "CHANGELOG.md")
    return [line[3:] for line in diff.splitlines() if line.startswith("+- ")]


def record(releases, entry):
    """The releases with the entry added at the end, or in place of the entry of its version."""
    kept = [release if release.get("version") != entry["version"] else entry for release in releases]
    return kept if entry in kept else kept + [entry]


def write(path, document):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as file:
        json.dump(document, file, indent=2, ensure_ascii=False)
        file.write("\n")
    os.chmod(file.name, 0o600)
    os.replace(file.name, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--version", help="default: macOS/VERSION")
    parser.add_argument("--commit", help="default: HEAD")
    parser.add_argument("--results", type=Path, help="journeys results; default: the newest for the commit")
    parser.add_argument("--suite", type=Path, help="the suite's step timings (BOTCHU_TEST_STEPS)")
    parser.add_argument("--since", help="the commit before the release's changes; default: the previous release's")
    parser.add_argument("--date", help="ISO 8601; default: now")
    args = parser.parse_args(argv)

    version = args.version or (ROOT / "macOS/VERSION").read_text().strip()
    commit = git("rev-parse", "--short=7", args.commit or "HEAD").strip()
    path = data_folder() / "testing/releases.json"
    releases = json.loads(path.read_text()).get("releases", []) if path.exists() else []
    earlier = [release for release in releases if release.get("version") != version]
    since = args.since or (earlier[-1]["commit"] if earlier else None)
    results = args.results or newest_results(commit)
    entry = {"version": version, "commit": commit,
             "date": args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "suite": suite(args.suite.read_text().splitlines()) if args.suite and args.suite.exists() else None,
             "journeys": journeys(json.loads(results.read_text())) if results else None,
             "changes": changes(since, commit) if since else []}
    write(path, {"releases": record(releases, entry)})
    print(f"release-record: {version} ({commit}) in {path}: {len(entry['changes'])} changes, "
          f"{len(entry['journeys']['steps']) if entry['journeys'] else 'no'} journey steps, "
          f"suite {entry['suite']['seconds'] if entry['suite'] else 'unknown'}")


if __name__ == "__main__":
    sys.exit(main())
