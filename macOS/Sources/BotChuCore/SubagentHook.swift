import Foundation

/// A stdlib-only Python 3 helper, identical on macOS and SSH hosts. The remote installer checks
/// Python before starting a turn. Every path is supplied as data, never interpolated into a shell.
public enum SubagentHookInstaller {
    @discardableResult public static func install(binDirectory: URL = SubagentIPC.defaultBinDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = binDirectory.appendingPathComponent("botchu-subagent")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    public static let script = #"""
#!/usr/bin/env python3

import argparse
import datetime
import json
import os
import pathlib
import sys
import tempfile
import time
import uuid

os.umask(0o077)
ROOT = pathlib.Path(os.environ.get("BOTCHU_IPC_DIR", str(pathlib.Path.home() / ".botchu/ipc/subagents")))

def fail(message):
    raise RuntimeError(message)

def seconds(name, default, maximum):
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        fail(name + " must be a positive number")
    if not 0 < value <= maximum:
        fail(name + " must be between 0 and " + str(maximum))
    return value

def read_json(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)

def live():
    try:
        stamp = read_json(ROOT / "heartbeat.json")["updatedAt"]
        date = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        age = time.time() - date.timestamp()
        limit = seconds("BOTCHU_HEARTBEAT_TIMEOUT_SECONDS", 30, 300)
        if age < -60 or age > limit:
            fail("BotChu is no longer responding. Open BotChu and delegate again from an active turn.")
    except (OSError, ValueError, KeyError, TypeError):
        fail("BotChu is unavailable. Open BotChu and delegate again from an active turn.")

def canonical(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        fail("Invalid request or caller UUID: " + str(value))

def caller_uuid(name, required=False):
    value = os.environ.get(name)
    if not value and required:
        fail("Missing " + name + ". Run this helper inside an active BotChu turn.")
    return canonical(value) if value else None

def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def submit(args):
    live()
    if not args.agent.strip() or len(args.agent) > 256:
        fail("Provide an agent name, slug or UUID (up to 256 characters).")
    if not args.brief.strip() or len(args.brief) > 100000:
        fail("The delegated brief must contain 1–100000 characters.")
    if args.title and len(args.title) > 240:
        fail("The sub-agent title must be at most 240 characters.")
    try:
        depth = int(os.environ.get("BOTCHU_CALLER_DEPTH", "0"))
    except ValueError:
        fail("BOTCHU_CALLER_DEPTH must be an integer.")
    if not 0 <= depth < 3:
        fail("Maximum sub-agent depth (3) reached.")
    request_id = str(uuid.uuid4())
    request = {
        "id": request_id,
        "invocationID": caller_uuid("BOTCHU_INVOCATION_ID", True),
        "callerBotID": caller_uuid("BOTCHU_CALLER_BOT_ID", True),
        "callerTaskID": caller_uuid("BOTCHU_CALLER_TASK_ID"),
        "parentSubagentID": caller_uuid("BOTCHU_CALLER_SUBAGENT_ID"),
        "depth": depth,
        "targetAgent": args.agent,
        "title": args.title,
        "brief": args.brief,
        "workspaceMode": args.workspace,
        "callerWorkingDirectory": os.getcwd(),
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    atomic_json(ROOT / "requests" / (request_id + ".json"), request)
    return request_id

def wait_for(ids):
    pending = list(dict.fromkeys(canonical(value) for value in ids))
    started = time.monotonic()
    timeout = seconds("BOTCHU_WAIT_TIMEOUT_SECONDS", 7200, 86400)
    last_status = {}
    last_notice = started
    failed = False
    while pending:
        for request_id in list(pending):
            result_path = ROOT / "results" / (request_id + ".result.json")
            if result_path.exists():
                result = read_json(result_path)
                if canonical(result.get("id")) != request_id:
                    fail("Mismatched sub-agent result: " + request_id)
                phase = result.get("phase")
                if phase not in ("completed", "failed", "stopped"):
                    fail("Invalid terminal sub-agent result: " + request_id)
                print("=== Sub-agent: " + str(result.get("targetBotName", "Unknown")) + " (" + request_id + ") ===")
                output = result.get("handoffOutput", "")
                if output:
                    print(output)
                if result.get("errorMessage"):
                    print("Error: " + str(result["errorMessage"]))
                print("Status: " + phase, flush=True)
                failed = failed or phase != "completed"
                pending.remove(request_id)
                continue
            status_path = ROOT / "status" / (request_id + ".status.json")
            if status_path.exists():
                status = read_json(status_path)
                message = str(status.get("phase", "queued")) + ": " + str(status.get("activity", "Waiting"))
                if last_status.get(request_id) != message:
                    print("[" + request_id + "] " + message, file=sys.stderr, flush=True)
                    last_status[request_id] = message
        if not pending:
            break
        live()
        elapsed = time.monotonic() - started
        if elapsed > timeout:
            fail("Timed out waiting for " + ", ".join(pending) + ". Check the Sub-agents inspector in BotChu.")
        if time.monotonic() - last_notice >= 15:
            print("Waiting for " + str(len(pending)) + " BotChu sub-agent(s)…", file=sys.stderr, flush=True)
            last_notice = time.monotonic()
        time.sleep(0.25)
    return 1 if failed else 0

def main():
    parser = argparse.ArgumentParser(description="Delegate to BotChu agents; call/wait before finishing your turn.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List available bots, with UUIDs for ambiguous names")
    for command in ("call", "spawn"):
        child = commands.add_parser(command)
        child.add_argument("--agent", required=True)
        child.add_argument("--title")
        child.add_argument("--workspace", choices=("shared", "bot_home"), default="shared")
        child.add_argument("--brief", required=True)
    waiter = commands.add_parser("wait")
    waiter.add_argument("ids", nargs="+")
    args = parser.parse_args()
    if args.command == "list":
        roster = read_json(ROOT / "roster.json")
        for bot in roster:
            print(str(bot.get("emoji", "")) + " " + bot["slug"] + " — " + bot["name"] + " — " + bot.get("title", "") + " (" + bot["id"] + ")")
        return 0
    if args.command == "wait":
        return wait_for(args.ids)
    request_id = submit(args)
    if args.command == "spawn":
        print(request_id, flush=True)
        return 0
    return wait_for([request_id])

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
        print("botchu-subagent: " + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        print("botchu-subagent: interrupted; use BotChu's Stop control to stop the delegated work.", file=sys.stderr)
        sys.exit(130)
"""#
}
