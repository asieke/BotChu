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


def in_gate(snapshot, pid):
    ancestors = {}
    for line in snapshot.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        try:
            ancestors[int(fields[0])] = int(fields[1]), os.path.basename(fields[2]), shlex.split(fields[3])
        except ValueError:
            continue
    seen = set()
    while pid in ancestors and pid not in seen:
        seen.add(pid)
        parent, base, args = ancestors[pid]
        if base in ("bash", "sh", "zsh"):
            for index, argument in enumerate(args[:2]):
                if os.path.basename(argument) == "gate.sh" and args[index + 1:index + 2] == ["_run"]:
                    return True
        pid = parent
    return False


if __name__ == "__main__":
    if sys.argv[1:] == ["--stdin"]:
        snapshot = sys.stdin.read()
    else:
        # Darwin truncates comm to 16 columns when another field follows it, even with -ww.
        # Read it as the last field, then join argv by PID. This also keeps spaces in paths out
        # of the field splitting used below. A process exiting between snapshots is ignored.
        commands = subprocess.check_output(["ps", "-ww", "-axo", "pid=,ppid=,comm="], text=True)
        arguments = subprocess.check_output(["ps", "-ww", "-axo", "pid=,args="], text=True)
        argv = dict(line.split(None, 1) for line in arguments.splitlines() if len(line.split(None, 1)) == 2)
        rows = []
        for line in commands.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and fields[0] in argv:
                pid, parent, executable = fields
                rows.append(f"{pid} {parent} {os.path.basename(executable)} {argv[pid]}")
        snapshot = "\n".join(rows)
    if sys.argv[1:] == ["--in-gate"]:
        sys.exit(0 if in_gate(snapshot, os.getppid()) else 1)
    for line in busy_lines(snapshot):
        print(line)
