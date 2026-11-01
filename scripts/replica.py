#!/usr/bin/env python3
"""The replica of the owner's BotChu data that `scripts/test.sh --journeys-replica` runs the journeys on (#422).

refresh: copies BotChu's own data, never a CLI's login or a Keychain item: from the data folder,
index.json, inbox.json, usage.json, drafts and remote-bots; from each bot's folder, only `.botchu/`,
without its deployments, logs, evaluations, dispatch requests, usage logs and queued messages. In the
copy every account becomes the journeys' fake CLI profile, fields that could hold a token or key are
dropped, scheduled jobs are disabled, task checkouts and folders become empty read-only folders, and
every other path in the owner's home folder points into the replica (where nothing is). It writes
into a new folder beside the replica and swaps it in, under `sandbox-exec` with writes to the live
folders denied, so it can't change them. replica.json records when and the totals; nothing names a
bot or quotes a message.
status: when the replica was refreshed, and its totals.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser("~")
LIVE = Path(os.environ.get("BOTCHU_REPLICA_LIVE") or Path(HOME) / "Library/Application Support/BotChu")
REPLICA = Path(os.environ.get("BOTCHU_REPLICA") or Path(HOME) / "Library/Application Support/BotChu Replica")
# The profile the journeys add first with BOTCHU_PROFILE (Fixture.accountID).
FAKE_ACCOUNT = "custom-review-0"
FAKE_ACCOUNT_NAME = "Journey Claude"
TOP = ["index.json", "inbox.json", "usage.json", "drafts", "remote-bots"]
SKIP_IN_BOTCHU = {"deployments", "logs", "evaluations", "dispatch", "usage"}
SKIP_ANYWHERE = {"queued.jsonl", ".DS_Store"}
SECRET = re.compile(r"(token|secret|password|passphrase|credentials?|api_?key)$", re.IGNORECASE)
ACCOUNT_KEYS = {"accountID", "sessionAccountID"}
DROPPED_KEYS = {"accountProfile", "providerID"}


def clone(source, target):
    """An APFS clone of a file or folder (a plain copy elsewhere); reads the source only."""
    target.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["/bin/cp", "-cR", str(source), str(target)], capture_output=True).returncode != 0:
        subprocess.run(["/bin/cp", "-R", str(source), str(target)], check=True)


def slug(name, taken):
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "bot"
    candidate, n = base, 2
    while candidate in taken:
        candidate, n = f"{base}-{n}", n + 1
    taken.add(candidate)
    return candidate


def short(text):
    return hashlib.sha256(text.encode()).hexdigest()[:10]


def live_bots(live):
    """Each bot in the live index, with its folder: (entry, workspace)."""
    index = json.loads((live / "index.json").read_text())
    return [(entry, entry["workspace"]) for entry in index if isinstance(entry.get("workspace"), str)]


class Paths:
    """Where each live path goes in the replica: the data folder, each bot's folder, each task's
    checkout or folder (an empty read-only stub), and anything else in the home folder (nowhere)."""

    def __init__(self, live, replica):
        self.replica = replica
        self.prefixes = [(str(live), str(replica))]
        self.stubs = set()

    def add(self, source, target):
        self.prefixes.append((source.rstrip("/"), str(target)))

    def stub(self, path):
        if not isinstance(path, str) or not self.inside_home(path):
            return path
        mapped = self.map(path)
        if not mapped.startswith(str(self.replica / "missing")):
            self.stubs.add(Path(mapped))
            return mapped
        target = self.replica / "repos" / f"{Path(path).name or 'folder'}-{short(path)}"
        self.add(self.expand(path), target)
        self.stubs.add(target)
        return str(target)

    @staticmethod
    def expand(path):
        return HOME + path[1:] if path.startswith("~/") else path

    def inside_home(self, path):
        path = self.expand(path)
        return path == HOME or path.startswith(HOME + "/")

    def map(self, path):
        if not self.inside_home(path):
            return path
        path = self.expand(path)
        for source, target in sorted(self.prefixes, key=lambda p: -len(p[0])):
            if path == source or path.startswith(source + "/"):
                return target + path[len(source):]
        return str(self.replica / "missing" / short(path))


def scrub(value, paths, job=False):
    """The JSON value with paths moved, accounts on the fake profile and secret fields dropped."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in DROPPED_KEYS or SECRET.search(key):
                continue
            if key in ACCOUNT_KEYS and isinstance(item, str):
                out[key] = FAKE_ACCOUNT
            elif key == "accountName" and isinstance(item, str):
                out[key] = FAKE_ACCOUNT_NAME
            elif job and key == "enabled" and isinstance(item, bool):
                out[key] = False
            else:
                out[key] = scrub(item, paths, job)
        return out
    if isinstance(value, list):
        return [scrub(item, paths, job) for item in value]
    if isinstance(value, str):
        return paths.map(value)
    return value


def count(replica):
    totals = {"bots": 0, "principal": 0, "areas": 0, "hidden_areas": 0, "tasks": 0, "closed_tasks": 0,
              "job_runs": 0, "subagent_runs": 0, "deliveries": 0}
    for entry in json.loads((replica / "index.json").read_text()):
        totals["bots"] += 1
        botchu = Path(entry["workspace"]) / ".botchu"
        try:
            bot = json.loads((botchu / "bot.json").read_text())
        except (OSError, ValueError):
            continue
        if bot.get("role", "agent") != "specialist" and bot.get("kind") != "remoteQueue":
            totals["principal"] += 1
        for file in botchu.glob("tasks/*/task.json"):
            try:
                task = json.loads(file.read_text())
            except ValueError:
                continue
            closed = task.get("archivedAt") is not None
            if task.get("area"):
                totals["hidden_areas" if closed else "areas"] += 1
            elif task.get("jobRun"):
                totals["job_runs"] += 1
            else:
                totals["closed_tasks" if closed else "tasks"] += 1
        totals["subagent_runs"] += len(list(botchu.glob("subagents/*/run.json"))) + len(list(botchu.glob("tasks/*/subagents/*/run.json")))
        totals["deliveries"] += len(list(botchu.glob("inbox/*/delivery.json")))
    totals["runs"] = totals["job_runs"] + totals["subagent_runs"]
    return totals


def build(live, target):
    """Makes the replica in `target`, which must not exist, from `live`; returns its totals."""
    paths = Paths(live, REPLICA)
    target.mkdir(parents=True)
    for name in TOP:
        if (live / name).exists():
            clone(live / name, target / name)
    taken = set()
    for entry, workspace in live_bots(live):
        folder = REPLICA / "bots" / slug(Path(workspace).name, taken)
        paths.add(workspace, folder)
        source = Path(workspace) / ".botchu"
        if source.is_dir():
            clone(source, target / folder.relative_to(REPLICA) / ".botchu")
    for path in sorted(target.rglob("*"), reverse=True):
        rel = path.relative_to(target).parts
        in_botchu = ".botchu" in rel and rel.index(".botchu") == len(rel) - 2
        if path.name in SKIP_ANYWHERE or (in_botchu and path.name in SKIP_IN_BOTCHU):
            shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
    # Task checkouts and folders first, so the paths under them land in their stubs.
    tasks = [json.loads(file.read_text()) for file in target.glob("bots/*/.botchu/tasks/*/task.json")]
    for key in ("checkout", "folder"):
        for task in tasks:
            paths.stub(task.get(key))
    for file in target.rglob("*.json"):
        if file.is_symlink():
            file.unlink()
            continue
        try:
            value = json.loads(file.read_text())
        except (ValueError, UnicodeDecodeError):
            file.unlink()
            continue
        file.write_text(json.dumps(scrub(value, paths, job=file.name == "job.json"), indent=1, ensure_ascii=False) + "\n")
    # Each an empty read-only folder; one inside another's stays missing, as a removed worktree is.
    made = []
    for stub in sorted(paths.stubs, key=lambda p: len(str(p))):
        local = target / stub.relative_to(REPLICA)
        if local.exists() or any(stub.is_relative_to(other) for other in made):
            continue
        local.mkdir(parents=True)
        made.append(stub)
    for stub in made:
        (target / stub.relative_to(REPLICA)).chmod(0o555)


def refresh(args):
    if not (LIVE / "index.json").is_file():
        sys.exit(f"replica: no BotChu data at {LIVE}")
    if os.environ.get("BOTCHU_REPLICA_SANDBOXED") != "1" and not args.no_sandbox:
        # Writes to the live data folder and every bot's folder are denied while it copies.
        def quoted(path):
            return '"' + os.path.realpath(path).replace("\\", "\\\\").replace('"', '\\"') + '"'
        live = [LIVE] + [Path(workspace) for _, workspace in live_bots(LIVE)]
        profile = "(version 1)(allow default)(deny file-write* " + " ".join(f"(subpath {quoted(p)})" for p in live) + ")"
        env = dict(os.environ, BOTCHU_REPLICA_SANDBOXED="1", PYTHONDONTWRITEBYTECODE="1")
        os.execve("/usr/bin/sandbox-exec", ["sandbox-exec", "-p", profile, sys.executable, "-I", os.path.abspath(__file__), "refresh"], env)
    building = REPLICA.with_name(REPLICA.name + ".new")
    old = REPLICA.with_name(REPLICA.name + ".old")
    for leftover in (building, old):
        remove(leftover)
    build(LIVE, building)
    if REPLICA.exists():
        REPLICA.rename(old)
    building.rename(REPLICA)
    remove(old)
    totals = count(REPLICA)
    (REPLICA / "replica.json").write_text(json.dumps({
        "refreshedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "account": FAKE_ACCOUNT, "totals": totals}, indent=1) + "\n")
    print(f"replica: refreshed {REPLICA}: {summary(totals)}")


def remove(folder):
    if not folder.exists():
        return
    for path in folder.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            path.chmod(0o755)
    shutil.rmtree(folder)


def summary(totals):
    return ", ".join(f"{value} {key.replace('_', ' ')}" for key, value in totals.items())


def status(_):
    try:
        info = json.loads((REPLICA / "replica.json").read_text())
    except (OSError, ValueError):
        print("no replica: run scripts/replica.sh refresh")
        return
    print(f"replica: {REPLICA}, refreshed {info['refreshedAt']}: {summary(info['totals'])}")


def main():
    parser = argparse.ArgumentParser(prog="scripts/replica.sh", description="The replica of BotChu's data the replica journeys run on.")
    commands = parser.add_subparsers(dest="command", required=True)
    refresh_parser = commands.add_parser("refresh", help="rebuild the replica from the live data")
    refresh_parser.add_argument("--no-sandbox", action="store_true", help=argparse.SUPPRESS)
    commands.add_parser("status", help="when the replica was refreshed, and its totals")
    args = parser.parse_args()
    {"refresh": refresh, "status": status}[args.command](args)


if __name__ == "__main__":
    main()
