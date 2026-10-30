#!/usr/bin/env python3
"""Compare a journeys run with the baseline and the runs before it on main, as Markdown, without dependencies.

Reads the newest results file in the history folder (or --results), macOS/Journeys/baseline.json, and,
for each step, its 3 newest earlier measurements at other commits on origin/main. Prints a summary
line, a header and one table, regressions first; --write also saves it. The same inputs always give
the same bytes.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNS = Path(os.environ.get("BOTCHU_JOURNEYS_RUNS") or Path.home() / "Library/Caches/botchu-journeys/runs")
PRIOR = 3
# A step is slower or faster than its prior median past the harness's regression rule:
# more than 25 % and more than 3 ms.
SHARE = 0.25
MILLISECONDS = 3.0
ORDER = ["FAILED", "slower", "ratcheted", "faster", "ok"]
NONE = "—"


def median(values):
    if not values:
        return None
    values = sorted(values)
    middle = len(values) // 2
    return values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2


def read_runs(folder):
    """Every results file in the folder, oldest first; one that can't be read is left out."""
    runs = []
    for path in sorted(Path(folder).glob("*.json")):
        try:
            run = json.loads(path.read_text())
            run["recordedAt"], run["steps"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"journeys-report: cannot read {path}: {error}", file=sys.stderr)
            continue
        runs.append((path, run))
    return sorted(runs, key=lambda item: (item[1]["recordedAt"], item[0].name))


def on_main():
    """Whether a commit (short or full) is on origin/main."""
    try:
        commits = subprocess.run(["git", "rev-list", "origin/main"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        commits = []
    prefixes = {}
    def check(commit):
        if not commit:
            return False
        if len(commit) not in prefixes:
            prefixes[len(commit)] = {full[:len(commit)] for full in commits}
        return commit in prefixes[len(commit)]
    return check


def prior_runs(runs, this, is_on_main):
    """The runs recorded before this one at other commits on main, newest first."""
    return [run for _, run in reversed(runs)
            if run["recordedAt"] < this["recordedAt"] and run.get("commit") != this.get("commit") and is_on_main(run.get("commit", ""))]


def verdict(step, prior):
    if not step.get("passed"):
        return "FAILED"
    value = step.get("median")
    if value is not None and prior is not None:
        if value > prior * (1 + SHARE) and value - prior > MILLISECONDS:
            return "slower"
        if value < prior * (1 - SHARE) and prior - value > MILLISECONDS:
            return "faster"
    return "ratcheted" if step.get("ratcheted") else "ok"


def compare(this, baseline, prior):
    """One row per step of this run, regressions first, then by journey."""
    rows = []
    for step in this["steps"]:
        earlier = [run["medians"][step["key"]] for run in prior if step["key"] in run.get("medians", {})][:PRIOR]
        reference = median(earlier)
        value = step.get("median")
        rows.append({
            "step": step,
            "baseline": baseline.get("medians", {}).get(step["key"]),
            "prior": reference,
            "delta": (value / reference - 1) * 100 if value is not None and reference else None,
            "verdict": verdict(step, reference),
        })
    return sorted(rows, key=lambda row: (ORDER.index(row["verdict"]), row["step"]["journey"], row["step"]["step"]))


def ms(value):
    return NONE if value is None else f"{value:.1f}"


def loads(values):
    return " ".join(f"{value:g}" for value in values)


def summary(this, rows, prior):
    count = {name: sum(row["verdict"] == name for row in rows) for name in ORDER}
    passed = sum(1 for row in rows if row["step"].get("passed"))
    line = (f"Latency report for BotChu {this.get('commit') or 'unknown'} on {this.get('branch') or 'a detached HEAD'}: "
            f"{passed} of {len(rows)} journey steps passed; ")
    if prior:
        line += (f"{count['FAILED']} FAILED, {count['slower']} slower, {count['faster']} faster and {count['ratcheted']} ratcheted "
                 f"against the median of up to {PRIOR} prior runs on main.")
    else:
        line += f"{count['FAILED']} FAILED and {count['ratcheted']} ratcheted; no prior runs on main to compare with yet."
    before, after = this.get("loadBefore") or [0], this.get("loadAfter") or [0]
    return line + f" Load {before[0]:g} → {after[0]:g}."


def report(this, baseline, runs, is_on_main):
    prior = prior_runs(runs, this, is_on_main)
    rows = compare(this, baseline, prior)
    recorded = this["recordedAt"].replace("T", " ").replace("Z", " UTC")
    header = [f"commit {this.get('commit') or 'unknown'}", f"branch {this.get('branch') or 'detached HEAD'}", this.get("machine", "")]
    if this.get("hertz"):
        header.append(f"{this['hertz']} Hz")
    header += [f"load {loads(this.get('loadBefore', []))} → {loads(this.get('loadAfter', []))}",
               f"run {recorded}, {this.get('seconds', 0) // 60} min {this.get('seconds', 0) % 60} s",
               f"baseline {baseline.get('commit') or NONE}",
               "prior runs on main: " + (", ".join(run.get("commit", "") for run in prior[:PRIOR]) or NONE)]
    lines = [summary(this, rows, prior), "", " · ".join(part for part in header if part), "",
             f"| Step | Budget ms | Baseline ms | Prior-{PRIOR} median ms | This run ms | Delta | Verdict |",
             "|---|---:|---:|---:|---:|---:|---|"]
    for row in rows:
        step = row["step"]
        budget = ms(step["budget"]) + (f" → {ms(step['limit'])}" if step.get("ratcheted") else "")
        delta = NONE if row["delta"] is None else f"{round(row['delta']):+d} %"
        name = f"{step['journey']} {step['step']}".replace("|", "\\|")
        lines.append(f"| {name} | {budget} | {ms(row['baseline'])} | {ms(row['prior'])} | {ms(step.get('median'))} | {delta} | {row['verdict']} |")
    failures = [row["step"] for row in rows if row["verdict"] == "FAILED"]
    if failures:
        lines += ["", "Failures:"] + [f"- {step['journey']} {step['step']}: {step.get('failure') or 'failed'}" for step in failures]
    return "\n".join(lines) + "\n"


def main(arguments):
    parser = argparse.ArgumentParser(prog="scripts/journeys-report.py", description="Latency report of a journeys run.")
    parser.add_argument("--results", help="a results file (default: the newest in the history folder)")
    parser.add_argument("--write", help="also save the report to this file")
    options = parser.parse_args(arguments)
    runs = read_runs(RUNS)
    if options.results:
        path = Path(options.results).resolve()
        this = next((run for found, run in runs if found.resolve() == path), None)
        if this is None:
            try:
                this = json.loads(path.read_text())
            except (OSError, ValueError) as error:
                sys.exit(f"journeys-report: cannot read {path}: {error}")
    elif runs:
        this = runs[-1][1]
    else:
        sys.exit(f"journeys-report: no results in {RUNS}; run scripts/test.sh --journeys")
    try:
        baseline = json.loads((ROOT / "macOS/Journeys/baseline.json").read_text())
    except (OSError, ValueError):
        baseline = {}
    text = report(this, baseline, runs, on_main())
    if options.write:
        Path(options.write).write_text(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main(sys.argv[1:])
