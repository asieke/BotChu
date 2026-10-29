import Foundation

/// A stdlib-only Python 3 helper, identical on macOS and SSH hosts. The remote installer checks
/// Python before starting a turn. Every path is supplied as data, never interpolated into a shell.
public enum SubagentHookInstaller {
    /// The helper's commands, each a copy of `script`, which acts by the name it is run as:
    /// `botchu-subagent` starts sub-agent runs, `botchu-task` creates Tasks (#111), and
    /// `botchu-inbox` delivers to the owner's Inbox, `botchu-message` messages remote queue bots,
    /// and `botchu-secret` asks for direct, private delivery of a sensitive value.
    public static let commands = ["botchu-subagent", "botchu-task", "botchu-inbox", "botchu-message", "botchu-secret"]

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
import signal
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

def roster(tasks=False):
    for bot in read_json(ROOT / "roster.json"):
        # A specialist is only called as a sub-agent, so it can't get a Task.
        if bot.get("remote") or (tasks and bot.get("specialist")):
            continue
        role = " [specialist: sub-agent only]" if bot.get("specialist") else ""
        print(str(bot.get("emoji", "")) + " " + bot["slug"] + " — " + bot["name"] + " — " + bot.get("title", "") + " (" + bot["id"] + ")" + role)
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
    working = bool(result and result.get("alreadyWorking"))
    if result and result.get("taskID"):
        print(("Working Task: " if working else "Task: ") + str(result.get("taskTitle", "")) + " (" + result["taskID"] + ")")
    if result and result.get("targetBotID"):
        print("Agent: " + agent + " (" + result["targetBotID"] + ")")
    reason = str(result.get("errorMessage") or "") if result else ""
    earlier = " The same request created it before; no second Task was made." if result and result.get("existing") else ""
    print("Status: " + {
        "pending": "pending — BotChu has the request and hasn't created the Task yet. Check again with botchu-task status " + request_id + ".",
        "created": "created — the Task is recorded under " + agent + " and its first turn is still starting." + earlier,
        "started": "started — the Task's first turn is running under " + agent + "; it goes on independently of this turn." + earlier,
        "startFailed": "start failed — the Task is recorded under " + agent + ", but its first turn couldn't start: " + reason + earlier,
        "failed": "failed — " + reason + (" No Task was created; continue in the Working Task instead." if working
                                          else "" if result and result.get("taskID") else " No Task was created; fix that and run the same command again."),
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

def task_list(as_json):
    live()
    request_id = str(uuid.uuid4())
    atomic_json(ROOT / "requests" / (request_id + ".json"), {
        "kind": "taskList",
        "id": request_id,
        "invocationID": caller_uuid("BOTCHU_INVOCATION_ID", True),
        "callerBotID": caller_uuid("BOTCHU_CALLER_BOT_ID", True),
        "callerTaskID": caller_uuid("BOTCHU_CALLER_TASK_ID"),
        "parentSubagentID": caller_uuid("BOTCHU_CALLER_SUBAGENT_ID"),
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    started = time.monotonic()
    timeout = seconds("BOTCHU_WAIT_TIMEOUT_SECONDS", 30, 86400)
    path = ROOT / "results" / (request_id + ".result.json")
    while not path.exists():
        if time.monotonic() - started > timeout:
            fail("BotChu hasn't answered yet; run botchu-task list --mine again.")
        live()
        time.sleep(0.1)
    result = read_json(path)
    try:
        path.unlink()
    except OSError:
        pass
    if result.get("kind") != "taskList" or canonical(result.get("id")) != request_id:
        fail("Mismatched Tasks list: " + request_id)
    if result.get("errorMessage"):
        fail("No Tasks list: " + str(result["errorMessage"]))
    if as_json:
        # IDs as the text prints them: lowercase.
        tasks = [dict(task, id=canonical(task.get("id"))) for task in result.get("tasks") or []]
        print(json.dumps({"bot": {"id": canonical(result.get("botID")), "name": result.get("botName")}, "tasks": tasks},
                         ensure_ascii=False, indent=2), flush=True)
    else:
        print(str(result.get("text", "")), flush=True)
    return 0

def task_main():
    parser = argparse.ArgumentParser(prog="botchu-task", description="Create Tasks for BotChu bots: independent, parent-level "
        "conversations under the bot in BotChu's sidebar, which go on after this turn ends. For child work that "
        "returns a handoff to this turn, use botchu-subagent instead.")
    commands = parser.add_subparsers(dest="command", required=True)
    lister = commands.add_parser("list", help="List the bots that can own Tasks, with UUIDs for ambiguous names; "
        "with --mine, your own open Tasks")
    lister.add_argument("--mine", action="store_true", help="List your bot's open Tasks as BotChu's sidebar shows them, in its "
        "order: title, summary, state (Idle, Thinking…, Running a tool…), elapsed time or time since last activity, issue or "
        "pull request, branch and Task ID")
    lister.add_argument("--json", action="store_true", help="With --mine, print the same fields as JSON")
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
        if args.mine:
            return task_list(args.json)
        if args.json:
            fail("--json prints your own Tasks: use it with --mine.")
        return roster(tasks=True)
    if args.command == "status":
        request_id = canonical(args.id)
        return task_report(request_id, task_result(request_id))
    if not 0 <= args.wait <= 3600:
        fail("--wait must be between 0 and 3600 seconds.")
    return task_wait(task_submit(args), args.wait)

INBOX_FILE_BYTES = 20 << 20
INBOX_NOTE_BYTES = 160000

def checkout_repo():
    try:
        import subprocess
        url = subprocess.run(["git", "config", "--get", "remote.origin.url"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, ValueError):
        return None
    import re
    match = re.match(r"^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return match.group(1) + "/" + match.group(2) if match else None

def inbox_link(text, pull):
    import re
    text = text.strip()
    match = re.match(r"^https://github\.com/([^/]+)/([^/]+)/(pull|issues)/([0-9]+)", text)
    if match:
        return {"repo": match.group(1) + "/" + match.group(2), "number": int(match.group(4)), "pullRequest": match.group(3) == "pull"}
    match = re.match(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$", text)
    if match:
        return {"repo": match.group(1), "number": int(match.group(2)), "pullRequest": pull}
    match = re.match(r"^#?([0-9]+)$", text)
    if match:
        repo = checkout_repo()
        if not repo:
            fail("Give " + text + " as owner/name#number: this folder isn't a checkout of a GitHub repository.")
        return {"repo": repo, "number": int(match.group(1)), "pullRequest": pull}
    fail("Give a pull request or issue as owner/name#number, a number, or its GitHub URL: " + text)

def inbox_send(args):
    import shutil
    live()
    title = args.title.strip()
    if not title or len(title) > 200:
        fail("Give the delivery a title of 1–200 characters (--title).")
    if args.note is not None and args.note_file:
        fail("Use --note or --note-file, not both.")
    note = args.note or ""
    if args.note_file:
        try:
            note = pathlib.Path(args.note_file).expanduser().read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            fail("Couldn't read the note file: " + str(error))
    if len(note.encode("utf-8")) > INBOX_NOTE_BYTES:
        fail("The note must be at most 160 KB; send a longer text as a file (--file).")
    if (args.choice or args.recommend) and not args.ask:
        fail("--choice and --recommend answer a question: ask it with --ask.")
    if args.purpose == "needs-input" and not args.ask:
        fail("Needs input asks the one question you can't go on without: add --ask.")
    if args.ask and args.purpose not in ("needs-input", "review"):
        fail("A question (--ask) is for --purpose needs-input or review.")
    updates = None
    if args.update:
        try:
            updates = str(uuid.UUID(args.update.strip()))
        except ValueError:
            fail("--update takes the delivery ID that botchu-inbox send printed.")
    sources = []
    for path in args.file or []:
        source = pathlib.Path(path).expanduser().resolve()
        if not source.is_file():
            fail("Not a file: " + path)
        if source.name.startswith("."):
            fail("Send " + path + " under a name that doesn't start with a dot.")
        if source.stat().st_size > INBOX_FILE_BYTES:
            fail(path + " is larger than 20 MB.")
        if source.name in (other.name for other in sources):
            fail("Two files are called " + source.name + "; send one under another name.")
        sources.append(source)
    if len(sources) > 20:
        fail("Send at most 20 files.")
    links = [inbox_link(value, True) for value in args.pr or []] + [inbox_link(value, False) for value in args.issue or []]
    request_id = str(uuid.uuid4())
    staged = ROOT / "inbox" / request_id
    files = []
    if sources:
        staged.mkdir(parents=True, mode=0o700)
        for source in sources:
            copy = staged / source.name
            shutil.copyfile(source, copy)
            size = copy.stat().st_size
            if size > INBOX_FILE_BYTES:
                fail(str(source) + " grew past 20 MB while it was copied.")
            files.append({"name": source.name, "staged": "inbox/" + request_id + "/" + source.name, "bytes": size, "source": str(source)})
    delivery = {"purpose": args.purpose, "title": title, "note": note, "files": files, "links": links, "credits": args.credit or []}
    if updates:
        delivery["updates"] = updates
    if args.ask:
        delivery["question"] = {"text": args.ask, "choices": args.choice or []}
        if args.recommend:
            delivery["question"]["recommended"] = args.recommend
    atomic_json(ROOT / "requests" / (request_id + ".json"), {
        "kind": "inbox",
        "id": request_id,
        "invocationID": caller_uuid("BOTCHU_INVOCATION_ID", True),
        "callerBotID": caller_uuid("BOTCHU_CALLER_BOT_ID", True),
        "callerTaskID": caller_uuid("BOTCHU_CALLER_TASK_ID"),
        "parentSubagentID": caller_uuid("BOTCHU_CALLER_SUBAGENT_ID"),
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "delivery": delivery,
    })
    started = time.monotonic()
    path = ROOT / "results" / (request_id + ".result.json")
    while not path.exists():
        if time.monotonic() - started > args.wait:
            print("Pending — BotChu has the delivery and hasn't put it in the Inbox yet. Request: " + request_id, flush=True)
            return 1
        live()
        time.sleep(0.25)
    result = read_json(path)
    if result.get("kind") != "inbox" or canonical(result.get("id")) != request_id:
        fail("Mismatched delivery result: " + request_id)
    if not result.get("delivered"):
        fail("Not delivered: " + str(result.get("errorMessage") or "BotChu couldn't take it."))
    print(("Updated" if result.get("updated") else "Delivered") + " to your owner's Inbox: " + title, flush=True)
    print("Delivery: " + str(result.get("deliveryID")), flush=True)
    return 0

def inbox_main():
    parser = argparse.ArgumentParser(prog="botchu-inbox", description="Deliver something to your owner's Inbox in BotChu: "
        "a note, copies of files, pull requests and issues, and a question with choices. Their reply comes back into this conversation.")
    commands = parser.add_subparsers(dest="command", required=True)
    send = commands.add_parser("send", help="Send a delivery, or update the one sent with the same title in this turn")
    send.add_argument("--purpose", required=True, choices=["needs-input", "review", "completed", "fyi"],
                      help="needs-input: a question you can't go on without; review: work that needs their judgment; "
                      "completed: a meaningful finished outcome; fyi: an important finding that needs no answer")
    send.add_argument("--title", required=True)
    send.add_argument("--note", help="25-50 words in Markdown: the outcome, its context or your recommendation, the next action")
    send.add_argument("--note-file", help="A Markdown file to use as the note")
    send.add_argument("--file", action="append", help="A file to copy into the delivery (repeatable)")
    send.add_argument("--pr", action="append", help="A pull request: owner/name#n, n in this repository, or its URL (repeatable)")
    send.add_argument("--issue", action="append", help="An issue: owner/name#n, n in this repository, or its URL (repeatable)")
    send.add_argument("--ask", help="The question you can't go on without")
    send.add_argument("--choice", action="append", help="An answer to --ask your owner can pick in one click (repeatable)")
    send.add_argument("--recommend", help="The answer to --ask you would pick; it is offered in one click too")
    send.add_argument("--update", help="The ID of a delivery this conversation sent, to update it in a later turn")
    send.add_argument("--credit", action="append", help="Another bot whose work it is: its name, slug or UUID (repeatable)")
    send.add_argument("--wait", type=float, default=60, help="Seconds to wait for BotChu to take it (default 60)")
    args = parser.parse_args()
    if not 0 <= args.wait <= 600:
        fail("--wait must be between 0 and 600 seconds.")
    return inbox_send(args)

MESSAGE_FILE_BYTES = 10 << 20
MESSAGE_TEXT_BYTES = 100000

def message_roster():
    remotes = [bot for bot in read_json(ROOT / "roster.json") if bot.get("remote")]
    if not remotes:
        print("No remote bots are set up in BotChu.")
    for bot in remotes:
        print(str(bot.get("emoji", "")) + " " + bot["slug"] + " — " + bot["name"] + " — " + bot.get("title", "") + " (" + bot["id"] + ")")
    return 0

def message_send(args):
    import shutil
    live()
    if not args.agent.strip() or len(args.agent) > 256:
        fail("Name the remote bot: its name, slug or UUID (botchu-message list).")
    if args.text is not None and args.text_file:
        fail("Use --text or --text-file, not both.")
    text = args.text or ""
    if args.text_file:
        try:
            text = pathlib.Path(args.text_file).expanduser().read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            fail("Couldn't read the text file: " + str(error))
    if len(text.encode("utf-8")) > MESSAGE_TEXT_BYTES:
        fail("The message must be at most 100 KB; send a longer text as a file (--file).")
    sources = []
    for path in args.file or []:
        source = pathlib.Path(path).expanduser().resolve()
        if not source.is_file():
            fail("Not a file: " + path)
        if source.name.startswith("."):
            fail("Send " + path + " under a name that doesn't start with a dot.")
        if not 0 < source.stat().st_size <= MESSAGE_FILE_BYTES:
            fail(path + " is empty or larger than 10 MB.")
        if source.name in (other.name for other in sources):
            fail("Two files are called " + source.name + "; send one under another name.")
        sources.append(source)
    if len(sources) > 8:
        fail("Send at most 8 files.")
    if not text.strip() and not sources:
        fail("Send some text (--text) or a file (--file).")
    request_id = str(uuid.uuid4())
    staged = ROOT / "inbox" / request_id
    files = []
    if sources:
        staged.mkdir(parents=True, mode=0o700)
        for source in sources:
            copy = staged / source.name
            shutil.copyfile(source, copy)
            size = copy.stat().st_size
            if not 0 < size <= MESSAGE_FILE_BYTES:
                fail(str(source) + " changed size while it was copied.")
            files.append({"name": source.name, "staged": "inbox/" + request_id + "/" + source.name, "bytes": size, "source": str(source)})
    atomic_json(ROOT / "requests" / (request_id + ".json"), {
        "kind": "message",
        "id": request_id,
        "invocationID": caller_uuid("BOTCHU_INVOCATION_ID", True),
        "callerBotID": caller_uuid("BOTCHU_CALLER_BOT_ID", True),
        "callerTaskID": caller_uuid("BOTCHU_CALLER_TASK_ID"),
        "parentSubagentID": caller_uuid("BOTCHU_CALLER_SUBAGENT_ID"),
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "message": {"agent": args.agent, "text": text, "files": files},
    })
    started = time.monotonic()
    path = ROOT / "results" / (request_id + ".result.json")
    while not path.exists():
        if time.monotonic() - started > args.wait:
            print("Pending — BotChu has the message and hasn't queued it yet. Message: " + request_id, flush=True)
            return 1
        live()
        time.sleep(0.25)
    result = read_json(path)
    if result.get("kind") != "message" or canonical(result.get("id")) != request_id:
        fail("Mismatched message result: " + request_id)
    if not result.get("queued"):
        fail("Not sent: " + str(result.get("errorMessage") or "BotChu couldn't take it."))
    name = str(result.get("targetBotName") or args.agent)
    print("Sent to " + name + ". Its reply will arrive in this conversation as a new message, which starts a turn if this one "
          "has ended; don't wait for it.", flush=True)
    print("Message: " + request_id, flush=True)
    return 0

def message_main():
    parser = argparse.ArgumentParser(prog="botchu-message", description="Message a remote queue bot (one that runs on its own "
        "computer): it answers in its own time, and its reply comes back into this conversation as a new message.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="List the remote bots you can message")
    send = commands.add_parser("send", help="Send a remote bot a message")
    send.add_argument("--agent", required=True, help="The remote bot: its name, slug or UUID")
    send.add_argument("--text", help="The message")
    send.add_argument("--text-file", help="A file whose text is the message")
    send.add_argument("--file", action="append", help="A file to send with it, up to 10 MB (repeatable, at most 8)")
    send.add_argument("--wait", type=float, default=60, help="Seconds to wait for BotChu to queue it (default 60)")
    args = parser.parse_args()
    if args.command == "list":
        return message_roster()
    if not 0 <= args.wait <= 600:
        fail("--wait must be between 0 and 600 seconds.")
    return message_send(args)

def secret_main():
    parser = argparse.ArgumentParser(prog="botchu-secret", description="Request a sensitive value in BotChu's secure popup. Only status is returned; the value is saved directly to a new local file.")
    commands = parser.add_subparsers(dest="command", required=True)
    request = commands.add_parser("request")
    request.add_argument("--label", required=True, help="Describe the value needed; never include a secret")
    request.add_argument("--destination", required=True, help="Absolute path of a new file in an existing folder on this Mac")
    args = parser.parse_args()
    if not args.label.strip() or len(args.label) > 120 or any(ord(c) < 32 or ord(c) == 127 for c in args.label):
        fail("Provide a label of 1–120 characters without control characters.")
    if not os.path.isabs(args.destination):
        fail("The destination must be an absolute path to a new file.")
    live()
    request_id = str(uuid.uuid4())
    invocation = caller_uuid("BOTCHU_INVOCATION_ID", True)
    payload = {
        "kind": "secret", "id": request_id, "invocationID": invocation,
        "callerBotID": caller_uuid("BOTCHU_CALLER_BOT_ID", True),
        "callerTaskID": caller_uuid("BOTCHU_CALLER_TASK_ID"),
        "parentSubagentID": caller_uuid("BOTCHU_CALLER_SUBAGENT_ID"),
        "label": args.label, "destination": args.destination,
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    path = ROOT / "requests" / (request_id + ".json")
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    completed = False
    started = time.monotonic()
    try:
        atomic_json(path, payload)
        while time.monotonic() - started < 300:
            result_path = ROOT / "results" / (request_id + ".result.json")
            if result_path.exists():
                result = read_json(result_path)
                if result.get("kind") != "secret" or canonical(result.get("id")) != request_id:
                    fail("Invalid sensitive-input receipt.")
                status = result.get("status")
                if status not in ("saved", "cancelled", "expired", "rejected"):
                    fail("Invalid sensitive-input status.")
                completed = True
                reason = result.get("reason")
                reasons = {"malformed_request", "request_id_mismatch", "invalid_request", "caller_mismatch", "not_local", "expired", "invalid_destination",
                    "excluded_destination", "unavailable_destination", "unknown_bot", "ack_failed", "turn_ended",
                    "queue_full", "withdrawn_limit"}
                detail = " (" + reason + ")" if status == "rejected" and isinstance(reason, str) and reason in reasons else ""
                print("Sensitive input: " + status + detail + ". No value is returned to the agent.", flush=True)
                return 0 if status == "saved" else 1
            live()
            time.sleep(0.2)
        fail("Sensitive-input request expired; request it again if needed.")
    finally:
        if not completed:
            # A metadata-only cancellation also handles Ctrl-C and a lost heartbeat.
            cancellation_id = str(uuid.uuid4())
            atomic_json(ROOT / "requests" / (cancellation_id + ".json"),
                {"kind": "secretCancel", "id": cancellation_id, "requestID": request_id, "invocationID": invocation})

def main():
    if os.path.basename(sys.argv[0]) == "botchu-secret":
        return secret_main()
    if os.path.basename(sys.argv[0]) == "botchu-message":
        return message_main()
    if os.path.basename(sys.argv[0]) == "botchu-task":
        return task_main()
    if os.path.basename(sys.argv[0]) == "botchu-inbox":
        return inbox_main()
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
        print(os.path.basename(sys.argv[0]) + ": interrupted; use BotChu's Stop control to stop the work.", file=sys.stderr)
        sys.exit(130)
"""#
}
