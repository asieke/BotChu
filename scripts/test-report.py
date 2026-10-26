#!/usr/bin/env python3
"""Summarize SwiftPM's XCTest and Swift Testing xUnit files, without dependencies."""
import glob
import json
from pathlib import Path
import re
import shlex
import sys
import xml.etree.ElementTree as ET


def results(paths):
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError) as error:
            print(f"test: cannot read {path}: {error}", file=sys.stderr)
            continue
        for case in root.iter("testcase"):
            name = case.get("name", "")
            classname = case.get("classname", "")
            identifier = f"{classname}/{name}" if classname else name
            try:
                seconds = float(case.get("time", "0"))
            except ValueError:
                seconds = 0
            yield identifier, seconds, case.find("failure") is not None or case.find("error") is not None


def main(arguments):
    if arguments[0] == "--command":
        Path(arguments[1] + ".command.json").write_text(json.dumps(arguments[2:]))
    elif arguments[0] == "--failed":
        xml = Path(arguments[1])
        failed = sorted({name for name, _, failure in results(glob.glob(str(xml.with_suffix("")) + "*.xml")) if failure})
        command = json.loads(Path(str(xml) + ".command.json").read_text())
        selected = []
        skip = False
        for argument in command:
            if skip:
                skip = False
            elif argument in ("--filter", "--skip"):
                skip = True
            else:
                selected.append(argument)
        if failed:
            selected += ["--filter", "|".join(re.escape(name) for name in failed)]
            print("test: rerun only the failed tests:\n  " + shlex.join(selected))
        else:
            print("test: no failed test IDs were written (the runner may have exited early); retry this bundle:\n  " + shlex.join(command))
    else:
        tests = list(results(sorted(Path(arguments[0]).glob("*.xml"))))
        print(f"test: 20 slowest tests ({len(tests)} results)")
        for name, seconds, failure in sorted(tests, key=lambda item: item[1], reverse=True)[:20]:
            print(f"  {seconds:8.3f}s  {name}" + (" [failed]" if failure else ""))


if __name__ == "__main__":
    main(sys.argv[1:])
