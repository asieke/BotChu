import Foundation

/// A stdlib-only Python 3 helper, identical on macOS and SSH hosts. The remote installer checks
/// Python before starting a turn. Every path is supplied as data, never interpolated into a shell.
public enum SubagentHookInstaller {
    /// The helper's commands, each a copy of `script`, which acts by the name it is run as:
    /// `botchu-subagent` starts sub-agent runs, `botchu-task` creates Tasks (#111).
    public static let commands = ["botchu-subagent", "botchu-task"]

    @discardableResult public static func install(binDirectory: URL = SubagentIPC.defaultBinDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for command in commands {
            let file = binDirectory.appendingPathComponent(command)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return binDirectory.appendingPathComponent(commands[0])
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
                if result.get("kind") == "task":
                    fail(request_id + " is a Task, not a sub-agent run: Tasks go on independently. Check it with botchu-task status " + request_id + ".")
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

def roster():
    for bot in read_json(ROOT / "roster.json"):
        print(str(bot.get("emoji", "")) + " " + bot["slug"] + " — " + bot["name"] + " — " + bot.get("title", "") + " (" + bot["id"] + ")")
    return 0

TASK_PHASES = ("pending", "created", "started", "startFailed", "failed")

def task_submit(args):
    live()
    if not args.agent.strip() or len(args.agent) > 256:
        fail("Provide the bot that gets the Task: its name, slug or UUID (up to 256 characters).")
    if not args.repo.strip() or len(args.repo) > 512:
        fail("Provide the Task's repository, as owner/name (--repo).")
    brief = args.brief or ""
    if len(brief) > 100000:
        fail("The Task's brief must be at most 100000 characters.")
    if not brief.strip() and args.issue is None and args.pr is None and args.review is None:
        fail("Give the Task a brief (--brief), or an --issue, --pr or --review to work on.")
    if args.comment and args.review is None:
        fail("--comment posts a review: use it with --review.")
    task = {"agent": args.agent, "repo": args.repo}
    for key, value in (("task", brief or None), ("issue", args.issue), ("pullRequest", args.pr), ("review", args.review),
                       ("title", args.title), ("branch", args.branch), ("machine", args.machine)):
        if value is not None:
            task[key] = value
    if args.comment:
        task["comment"] = True
    request_id = str(uuid.uuid4())
    atomic_json(ROOT / "requests" / (request_id + ".json"), {
        "kind": "task",
        "id": request_id,
        "invocationID": caller_uuid("BOTCHU_INVOCATION_ID", True),
        "callerBotID": caller_uuid("BOTCHU_CALLER_BOT_ID", True),
        "callerTaskID": caller_uuid("BOTCHU_CALLER_TASK_ID"),
        "parentSubagentID": caller_uuid("BOTCHU_CALLER_SUBAGENT_ID"),
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "task": task,
    })
    return request_id

def task_result(request_id):
    path = ROOT / "results" / (request_id + ".result.json")
    if not path.exists():
        return None
    result = read_json(path)
    if result.get("kind") != "task" or canonical(result.get("id")) != request_id:
        fail(request_id + " isn't a Task request. Sub-agent runs are collected with botchu-subagent wait.")
    if result.get("phase") not in TASK_PHASES:
        fail("Invalid Task result: " + request_id)
    return result

def task_report(request_id, result):
    phase = result["phase"] if result else "pending"
    agent = str(result.get("targetBotName") or "the bot") if result else "the bot"
    if result and result.get("taskID"):
        print("Task: " + str(result.get("taskTitle", "")) + " (" + result["taskID"] + ")")
    if result and result.get("targetBotID"):
        print("Agent: " + agent + " (" + result["targetBotID"] + ")")
    reason = str(result.get("errorMessage") or "") if result else ""
    earlier = " The same request created it before; no second Task was made." if result and result.get("existing") else ""
    print("Status: " + {
        "pending": "pending — BotChu has the request and hasn't created the Task yet. Check again with botchu-task status " + request_id + ".",
        "created": "created — the Task is recorded under " + agent + " and its first turn is still starting." + earlier,
        "started": "started — the Task's first turn is running under " + agent + "; it goes on independently of this turn." + earlier,
        "startFailed": "start failed — the Task is recorded under " + agent + ", but its first turn couldn't start: " + reason + earlier,
        "failed": "failed — " + reason + ("" if result and result.get("taskID") else " No Task was created; fix that and run the same command again."),
    }[phase])
    print("Request: " + request_id, flush=True)
    return 1 if phase in ("startFailed", "failed") else 0

def task_wait(request_id, wait):
    started = time.monotonic()
    last = None
    while True:
        result = task_result(request_id)
        phase = result["phase"] if result else "pending"
        if phase in ("started", "startFailed", "failed"):
            return task_report(request_id, result)
        if phase != last:
            print("[" + request_id + "] " + phase, file=sys.stderr, flush=True)
            last = phase
        if time.monotonic() - started > wait:
            return task_report(request_id, result)
        live()
        time.sleep(0.25)

def task_main():
    parser = argparse.ArgumentParser(prog="botchu-task", description="Create Tasks for BotChu bots: independent, parent-level "
        "conversations under the bot in BotChu's sidebar, which go on after this turn ends. For child work that "
        "returns a handoff to this turn, use botchu-subagent instead.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List available bots, with UUIDs for ambiguous names")
    create = commands.add_parser("create", help="Create and start a Task under a bot")
    create.add_argument("--agent", required=True, help="The bot that gets the Task: its name, slug or UUID")
    create.add_argument("--repo", required=True, help="The repository, owner/name")
    create.add_argument("--brief", help="What to do; required without --issue, --pr or --review")
    create.add_argument("--issue", help="An issue to work on")
    create.add_argument("--pr", help="A pull request to continue")
    create.add_argument("--review", help="A pull request to review")
    create.add_argument("--comment", action="store_true", help="With --review, post the review on GitHub")
    create.add_argument("--title")
    create.add_argument("--branch")
    create.add_argument("--machine", help="The computer to work on, by its machine name")
    create.add_argument("--wait", type=float, default=120, help="Seconds to wait for the Task's first turn to start (default 120)")
    status = commands.add_parser("status", help="How a Task request made in this turn is going")
    status.add_argument("id")
    args = parser.parse_args()
    if args.command == "list":
        return roster()
    if args.command == "status":
        request_id = canonical(args.id)
        return task_report(request_id, task_result(request_id))
    if not 0 <= args.wait <= 3600:
        fail("--wait must be between 0 and 3600 seconds.")
    return task_wait(task_submit(args), args.wait)

def main():
    if os.path.basename(sys.argv[0]) == "botchu-task":
        return task_main()
    parser = argparse.ArgumentParser(description="Start sub-agent runs: child work of this turn, shown in BotChu's Sub-agents "
        "inspector, whose handoffs come back here; call/wait before finishing your turn. To create an independent Task "
        "for a bot, use botchu-task create instead.")
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
        return roster()
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
        print(os.path.basename(sys.argv[0]) + ": " + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        print("botchu-subagent: interrupted; use BotChu's Stop control to stop the delegated work.", file=sys.stderr)
        sys.exit(130)
"""#
}
