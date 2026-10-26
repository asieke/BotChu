#!/usr/bin/env python3
"""Find tests outside the gate. Other repositories keep the original gate policy."""
import os
import re
import shlex
import subprocess
import sys


def busy_lines(snapshot):
    processes = {}
    for line in snapshot.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, parent = int(fields[0]), int(fields[1])
            args = shlex.split(fields[3])
        except ValueError:
            continue
        base = os.path.basename(fields[2])
        shell = base in ("bash", "sh", "zsh")
        # ps prints a shell script as either /path/script or bash /path/script.
        script_args = args[:2] if shell else []
        wrapper = any(arg.endswith("/scripts/coord/botchu-windowless.sh") for arg in script_args)
        windows = shell and "--windows" in args and any(arg.endswith("/macOS/test.sh") or arg == "macOS/test.sh" for arg in script_args)
        candidate = base in ("swift-test", "swiftpm-testing-helper", "xctest") or "PackageTests" in base
        candidate |= shell and any(re.search(r"(^|/)(check|verify-pr|test)\.sh$", arg) for arg in script_args)
        processes[pid] = parent, wrapper, windows, candidate, line
    for pid, (_, _, _, candidate, line) in processes.items():
        if not candidate:
            continue
        seen = set()
        current = pid
        windowless = False
        while current in processes and current not in seen:
            seen.add(current)
            parent, wrapper, windows, _, _ = processes[current]
            if windows:
                break
            if wrapper:
                windowless = True
                break
            current = parent
        if not windowless:
            yield line[:200]


if __name__ == "__main__":
    snapshot = sys.stdin.read() if sys.argv[1:] == ["--stdin"] else subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,comm=,args="], text=True)
    for line in busy_lines(snapshot):
        print(line)
