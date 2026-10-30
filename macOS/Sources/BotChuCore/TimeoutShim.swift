import Foundation

/// `timeout` for every CLI session (#366): a stdlib-only Python 3 stand-in for GNU's, which macOS
/// lacks. It lives in the helpers' `fallback` folder, which `AgentRun.delegationShellPrefix` puts
/// last on PATH, so a real `timeout` anywhere on PATH (Homebrew's coreutils, a Linux host's) runs
/// instead, and so does `gtimeout` when there is one. At its limit it signals the command's process
/// group and exits 124, as GNU's does.
public enum TimeoutShim {
    public static let name = "timeout"
    /// Its folder in the helpers' bin folder, on this Mac and on a host.
    public static let folder = "fallback"

    public static func install(binDirectory: URL) throws {
        let directory = binDirectory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// Takes GNU's `-s`, `-k`, `-v`, `--preserve-status` and `--foreground`, and refuses other options
    /// (exit 125). The command runs in a process group of its own, which a stop signal sent to this
    /// script (a CLI ending its tool command) is passed on to. It never reaps the command before
    /// signalling it, so a signal can't reach a process that reused its ID.
    public static let script = #"""
#!/usr/bin/env python3
# BotChu's timeout (TimeoutShim.swift), last on PATH: a real timeout anywhere on PATH runs instead.

import os
import signal
import subprocess
import sys

OPTIONS = "-s SIGNAL, -k DURATION, -v, --preserve-status and --foreground"
USAGE = ("Usage: timeout [OPTION] DURATION COMMAND [ARG]...\nOptions: " + OPTIONS
         + ". DURATION is a number with an optional s, m, h or d; 0 means no limit.")
STOPS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT)

def fail(message, status=125):
    print("timeout: " + message, file=sys.stderr, flush=True)
    sys.exit(status)

def gtimeout():
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        path = os.path.join(folder, "gtimeout")
        if os.path.isabs(folder) and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

def duration(text):
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    number, unit = (text[:-1], units[text[-1]]) if text[-1:] in units else (text, 1)
    try:
        value = float(number) * unit
    except ValueError:
        value = -1.0
    if not value >= 0:
        fail("invalid time interval '" + text + "'\n" + USAGE)
    return 0.0 if value == float("inf") else value

def signal_number(text):
    name = text.upper()
    if name.isdigit():
        return int(name)
    name = name[3:] if name.startswith("SIG") else name
    number = getattr(signal, "SIG" + name, None) if name.isalnum() else None
    if not isinstance(number, int):
        fail("invalid signal '" + text + "'")
    return int(number)

def signal_name(number):
    try:
        return signal.Signals(number).name[3:]
    except ValueError:
        return str(number)

def parse(args):
    settings = {"signal": signal.SIGTERM, "kill": 0.0, "preserve": False, "foreground": False, "verbose": False}
    def take(option, value):
        if value is None:
            if not args:
                fail("option '" + option + "' requires an argument\n" + USAGE)
            value = args.pop(0)
        if option in ("-s", "--signal"):
            settings["signal"] = signal_number(value)
        else:
            settings["kill"] = duration(value)
    # Options end at the first operand, as GNU's do, so `timeout 5 ls -l` passes -l on.
    while args and args[0].startswith("-") and args[0] != "-":
        arg = args.pop(0)
        if arg == "--":
            break
        if arg.startswith("--"):
            name, equals, value = arg.partition("=")
            if name in ("--signal", "--kill-after"):
                take(name, value if equals else None)
            elif equals:
                fail("option '" + name + "' doesn't take an argument")
            elif name in ("--preserve-status", "--foreground", "--verbose"):
                settings[name[2:].split("-")[0]] = True
            elif name == "--help":
                print(USAGE)
                sys.exit(0)
            elif name == "--version":
                print("timeout (BotChu)")
                sys.exit(0)
            else:
                fail("unsupported option '" + arg + "'; BotChu's timeout takes " + OPTIONS)
            continue
        flags = arg[1:]
        while flags:
            flag, flags = flags[0], flags[1:]
            if flag in "sk":
                take("-" + flag, flags or None)
                flags = ""
            elif flag == "v":
                settings["verbose"] = True
            else:
                fail("unsupported option '-" + flag + "'; BotChu's timeout takes " + OPTIONS)
    if len(args) < 2:
        fail("missing operand\n" + USAGE)
    return settings, duration(args[0]), args[1:]

def main():
    real = gtimeout()
    if real:
        try:
            os.execv(real, ["timeout"] + sys.argv[1:])
        except OSError:
            pass
    settings, limit, command = parse(sys.argv[1:])
    # Stop signals this was started ignoring stay ignored, for the command too (nohup).
    stops = [number for number in STOPS if signal.getsignal(number) != signal.SIG_IGN]
    pending = []
    for number in stops:
        signal.signal(number, lambda number, frame: pending.append(number))
    group = {}
    if not settings["foreground"]:
        group = {"process_group": 0} if sys.version_info >= (3, 11) else {"preexec_fn": os.setpgrp}
    try:
        child = subprocess.Popen(command, close_fds=False, **group)
    except FileNotFoundError as error:
        fail("failed to run command '" + command[0] + "': " + (error.strerror or "No such file or directory"), 127)
    except OSError as error:
        fail("failed to run command '" + command[0] + "': " + (error.strerror or str(error)), 126)

    # From here this loop is the only place the command is reaped, so every signal below reaches it, or
    # its process group, before its ID can be reused.
    waited = set(stops) | {signal.SIGCHLD, signal.SIGALRM}
    signal.pthread_sigmask(signal.SIG_BLOCK, waited)
    # macOS drops a blocked SIGCHLD left at its default (ignore), so give it a handler to stay pending.
    signal.signal(signal.SIGCHLD, lambda number, frame: None)

    def send(number):
        try:
            if settings["foreground"]:
                os.kill(child.pid, number)
            else:
                os.killpg(child.pid, number)
        except OSError:
            pass
        if number not in (signal.SIGKILL, signal.SIGCONT):
            send(signal.SIGCONT)

    for number in pending:
        send(number)
    if limit:
        signal.setitimer(signal.ITIMER_REAL, limit)
    timed_out = False
    while True:
        pid, status = os.waitpid(child.pid, os.WNOHANG)
        if pid:
            break
        number = signal.sigwait(waited)
        if number == signal.SIGALRM:
            # The signal at the limit, then KILL after -k's duration if it's still running.
            number = signal.SIGKILL if timed_out else settings["signal"]
            if settings["verbose"]:
                print("timeout: sending signal " + signal_name(number) + " to command '" + command[0] + "'",
                      file=sys.stderr, flush=True)
            if not timed_out and settings["kill"]:
                signal.setitimer(signal.ITIMER_REAL, settings["kill"])
            timed_out = True
            send(number)
        elif number != signal.SIGCHLD:
            send(number)
    ended = os.WTERMSIG(status) if os.WIFSIGNALED(status) else 0
    child.returncode = -ended if ended else os.WEXITSTATUS(status)
    # At the limit 124, unless KILL ended it (137, as GNU's) or --preserve-status asks for its own; a
    # command a signal ended otherwise gives 128 + the signal, as shells report it.
    if timed_out and not settings["preserve"] and ended != signal.SIGKILL:
        return 124
    return 128 + ended if ended else child.returncode

if __name__ == "__main__":
    sys.exit(main())
"""#
}
