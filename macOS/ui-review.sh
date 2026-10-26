#!/usr/bin/env bash
# Open a freshly built BotChu on throwaway data, so its screens can be checked without touching real
# bots or needing screen-recording permission: the app writes a PNG of each of its windows into the
# snapshot folder every second (DevHooks.swift). Two demo bots are seeded, the first (selected) with a short
# sample conversation and memory, in the layout before bot folders, so each run also migrates them, and
# two tasks in a throwaway repository.
#   macOS/ui-review.sh                     # just open it
#   macOS/ui-review.sh "Hello"             # and send "Hello" to the first bot (a real turn)
#   BOTCHU_OPEN=editor macOS/ui-review.sh  # or open the new-bot editor (or settings)
#   BOTCHU_OPEN=settings BOTCHU_SETTINGS=telegram macOS/ui-review.sh  # Settings, on that page
#   BOTCHU_PET=<pet folder> macOS/ui-review.sh           # and give the first bot this pet
#   BOTCHU_DRAW_PET="a brass robot" macOS/ui-review.sh  # or make it one (real runs; costs OpenRouter credit)
#   BOTCHU_TAB=1 macOS/ui-review.sh        # show the first bot's first task tab (0 is Home)
#   BOTCHU_SECTION=Research macOS/ui-review.sh  # move the first bot into a sidebar section of that name
#   BOTCHU_DRAFT='One\nTwo' macOS/ui-review.sh   # with this draft in the message box (\n: a new line)
#   BOTCHU_TYPE='Ask @co{tab}to look' macOS/ui-review.sh  # type this into the message box, as keys
#                                          # ({down}, {up}, {tab}, {return}, {escape} press those)
#   BOTCHU_OPEN=agents BOTCHU_SEARCH=res macOS/ui-review.sh  # open Agents with that search
#   BOTCHU_DEMO=activity BOTCHU_TAB=1 macOS/ui-review.sh  # that tab as a long agent run (in memory)
#   BOTCHU_DEMO=tasks BOTCHU_WINDOW=wide BOTCHU_TAB=3 macOS/ui-review.sh
#                                          # six more tasks in memory, a tab in every state, in the
#                                          # column beside the chat (BOTCHU_WINDOW=compact: the rail)
#   BOTCHU_FAKE_HOST=1 BOTCHU_TASK="hello-world|<task>|Far Mac" macOS/ui-review.sh
#                                          # a task on a host, "Far Mac", whose ssh is a stand-in that
#                                          # runs the command here, in $data/far (a real turn)
#   BOTCHU_TASK="hello-world|Add a line" macOS/ui-review.sh  # start a task (a real turn on Claude Dev)
#   BOTCHU_OPEN=report macOS/ui-review.sh  # open Report a Bug or Feature
#   BOTCHU_OPEN=providers BOTCHU_USAGE=mixed BOTCHU_PROFILE="A long profile name|claude|claude-long" macOS/ui-review.sh
#                                          # Providers with a row in each usage state, and an added profile
#   BOTCHU_WINDOW=1908x960 macOS/ui-review.sh  # at that window size (compact: its minimum width)
#   BOTCHU_OPEN=projects BOTCHU_PROJECT=<owner/name> BOTCHU_PROJECT_TAB=issues BOTCHU_PROJECT_ITEM=<number> macOS/ui-review.sh
#                                          # open Projects with that repository's sidebar, on a tab and an
#                                          # issue or pull request there (read with your gh login)
#   BOTCHU_INBOX=sample BOTCHU_OPEN=inbox macOS/ui-review.sh  # the Inbox with sample deliveries (replied: the
#                                          # first answered from it); BOTCHU_INBOX_ITEM=<id> reads that one
#   BOTCHU_JOBS=sample BOTCHU_OPEN=jobs macOS/ui-review.sh  # Jobs, with sample jobs in every state and
#                                          # history (none ever runs); BOTCHU_OPEN=job-editor or job-history
#                                          # opens a new job's editor or the first job's history instead,
#                                          # job-model or job-effort a new job's picker, and job-edit with
#                                          # BOTCHU_JOB="Check the deploy" that job's editor
#   BOTCHU_REPORT="It crashed" macOS/ui-review.sh  # and file this report, with a stand-in gh that
#                                          # keeps it in $data/reports (BOTCHU_REPORT_FAIL=1: it fails),
#                                          # with the window's screenshot (BOTCHU_SCREENSHOT_FAIL=1: none)
# Prints the snapshot folder. Quit the app with `pkill -x BotChu` when done.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
data=$(mktemp -d "${TMPDIR:-/tmp}/botchu-ui.XXXXXX")
mkdir -p "$data/snapshots"
cat > "$data/bots.json" <<JSON
[{"id":"8C1F6A2E-5B7D-4E8A-9C3B-2A1D0F4E6B71","name":"Scout","emoji":"🔭","title":"Research helper",
  "instructions":"Be brief and friendly.","accountID":"claude-dev","model":"","workspace":"$data/bots/scout",
  "createdAt":"2026-10-22T03:00:00Z"},
 {"id":"1D2C3B4A-0000-4000-8000-000000000002","name":"Coder","emoji":"🛠️","title":"","instructions":"",
  "accountID":"codex-dev","model":"","workspace":"$data/bots/coder","createdAt":"2026-10-22T03:00:00Z"}]
JSON
# A short sample conversation and memory for Scout, so its screens have something to show.
mkdir -p "$data/threads" "$data/bots/scout"
cat > "$data/threads/8C1F6A2E-5B7D-4E8A-9C3B-2A1D0F4E6B71.json" <<'JSON'
[{"id":"00000000-0000-4000-8000-000000000001","role":"note","text":"Scout was created on Claude Dev","date":"2026-10-22T03:00:00Z"},
 {"id":"00000000-0000-4000-8000-000000000002","role":"assistant","date":"2026-10-22T03:00:05Z",
  "text":"I'm Scout, your research helper. What should I look into first?"},
 {"id":"00000000-0000-4000-8000-000000000003","role":"user","date":"2026-10-22T03:01:00Z",
  "text":"What's in your workspace? I like short answers."},
 {"id":"00000000-0000-4000-8000-000000000004","role":"tool","text":"","date":"2026-10-22T03:01:03Z","toolID":"t1",
  "toolName":"Bash","toolInput":"ls","toolOutput":"AGENTS.md\nCLAUDE.md\nGEMINI.md\nMEMORY.md\n","toolState":"done"},
 {"id":"00000000-0000-4000-8000-000000000005","role":"assistant","date":"2026-10-22T03:01:06Z",
  "text":"## All three workers reported back\n\nThe ranges are $p_1 \\dots p_{1000}$, $p_{1001} \\dots p_{2000}$ and $p_{2001} \\dots p_{3000}$.\n\n| Subagent | First prime | Last prime | Sum |\n| :--- | ---: | ---: | ---: |\n| [Worker 1](https://example.com/1) | $2$ | $7,919$ | **3,682,913** |\n| Worker 2 | $7,927$ | $17,389$ | **12,591,714** |\n| Worker 3 | $17,393$ | $27,449$ | **22,370,584** |\n| **Total** | $2$ | $27,449$ | **38,645,211** |\n\n$$3,682,913 + 12,591,714 + 22,370,584 = \\mathbf{38,645,211}$$\n\n1. Each worker checked its range.\n   - No primes overlap.\n2. Added their results.\n\n> All results are ready.\n\n```swift\nlet answer = 38_645_211\nprint(answer)\n```\n\n```mermaid\nflowchart LR\n  subgraph BotChu[BotChu]\n    Chat[Chat stream]\n  end\n  subgraph Local[This Mac]\n    Worktree[Git worktree]\n  end\n  subgraph GitHub[GitHub]\n    PR[Pull request]\n  end\n  Chat -->|Spawn work| Worktree\n  Worktree -->|Push and check| PR\n  PR -->|Review| Chat\n```"},
 {"id":"00000000-0000-4000-8000-000000000006","role":"receipt","date":"2026-10-22T03:02:41Z",
  "text":"hello-world · Add a greeting finished its turn · PR #7","taskID":"7A0C2D4E-1B3F-4C5D-8E9F-0A1B2C3D4E5F"}]
JSON
printf '# Scout\n\nWhat Scout has learned and keeps across conversations.\n\n- Prefers short answers.\n- Works on BotChu, a macOS app.\n' > "$data/bots/scout/MEMORY.md"
# A repository in the repositories folder ($data/repos), cloned from a local origin so tasks never reach
# GitHub, with a task worktree, and two tasks of Scout's there (named as if on GitHub): one that opened a
# pull request, and one whose last turn failed.
repo="$data/repos/hello-world"
git -c init.defaultBranch=main init -q --bare "$data/origin/hello-world.git"
git clone -q "$data/origin/hello-world.git" "$repo" 2>/dev/null
printf '# Hello\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=BotChu -c user.email=botchu@example.com commit -qm "First"
git -C "$repo" push -q origin HEAD:main
git -C "$repo" remote set-head origin main
printf '.claude/worktrees/\n' >> "$repo/.git/info/exclude"
git -C "$repo" worktree add -q -b feat/add-greeting "$repo/.claude/worktrees/feat-add-greeting"
tasks="$data/bots/scout/.botchu/tasks"
mkdir -p "$tasks/7a0c2d4e-1b3f-4c5d-8e9f-0a1b2c3d4e5f" "$tasks/7a0c2d4e-1b3f-4c5d-8e9f-0a1b2c3d4e60"
cat > "$tasks/7a0c2d4e-1b3f-4c5d-8e9f-0a1b2c3d4e5f/task.json" <<JSON
{"id":"7A0C2D4E-1B3F-4C5D-8E9F-0A1B2C3D4E5F","title":"hello-world · Add a greeting","repo":"octocat/hello-world",
 "checkout":"$repo","branch":"feat/add-greeting","folder":"$repo/.claude/worktrees/feat-add-greeting",
 "brief":"Add a friendly greeting to the README, then open a pull request.","origin":"home","accountID":"claude-dev",
 "model":"","sessionID":"00000000-0000-4000-8000-0000000000aa","sessionAccountID":"claude-dev",
 "createdAt":"2026-10-22T03:02:00Z","pullRequest":7}
JSON
cat > "$tasks/7a0c2d4e-1b3f-4c5d-8e9f-0a1b2c3d4e5f/thread.jsonl" <<'JSON'
{"date":"2026-10-22T03:02:00Z","id":"00000000-0000-4000-8000-000000000011","role":"note","text":"Scout started this task from Home"}
{"date":"2026-10-22T03:02:00Z","id":"00000000-0000-4000-8000-000000000012","role":"user","text":"Add a friendly greeting to the README, then open a pull request."}
{"date":"2026-10-22T03:02:30Z","id":"00000000-0000-4000-8000-000000000013","role":"tool","text":"","toolID":"t2","toolName":"Bash","toolInput":"gh pr create --fill","toolOutput":"https://github.com/octocat/hello-world/pull/7\n","toolState":"done"}
{"date":"2026-10-22T03:02:40Z","id":"00000000-0000-4000-8000-000000000014","role":"assistant","text":"Added the greeting and opened **pull request #7**. Next: wait for review."}
JSON
cat > "$tasks/7a0c2d4e-1b3f-4c5d-8e9f-0a1b2c3d4e60/task.json" <<JSON
{"id":"7A0C2D4E-1B3F-4C5D-8E9F-0A1B2C3D4E60","title":"hello-world #3","repo":"octocat/hello-world","checkout":"$repo",
 "branch":"feat/3-fix-typo","work":{"number":3,"title":"Fix the typo","url":"https://github.com/octocat/hello-world/issues/3","isPullRequest":false},
 "brief":"","origin":"owner","accountID":"codex-dev","model":"","createdAt":"2026-10-22T03:03:00Z"}
JSON
cat > "$tasks/7a0c2d4e-1b3f-4c5d-8e9f-0a1b2c3d4e60/thread.jsonl" <<'JSON'
{"date":"2026-10-22T03:03:00Z","id":"00000000-0000-4000-8000-000000000021","role":"user","text":"Work on issue #3 “Fix the typo”."}
{"date":"2026-10-22T03:03:05Z","id":"00000000-0000-4000-8000-000000000022","role":"error","text":"Couldn't make this task's worktree. Making the worktree for feat/3-fix-typo failed."}
JSON
# Sample deliveries in the Inbox (BOTCHU_INBOX=sample; replied: the first one answered from the Inbox,
# so Done, with the bot's answer in Scout's Home; done: every one Done), from Scout's Home (crediting Coder), a task of Scout's, and Coder's Home.
# BOTCHU_INBOX_ITEM=<delivery id> reads that one; ids are 00000000-0000-4000-9000-00000000000<n>.
if [ -n "${BOTCHU_INBOX:-}" ]; then
  python3 - "$data" "$BOTCHU_INBOX" <<'PY'
import datetime, json, os, sys
data, mode = sys.argv[1:3]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
def at(minutes): return (now - datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
scout, coder = "8C1F6A2E-5B7D-4E8A-9C3B-2A1D0F4E6B71", "1D2C3B4A-0000-4000-8000-000000000002"
task = "7A0C2D4E-1B3F-4C5D-8E9F-0A1B2C3D4E5F"
def did(n): return "00000000-0000-4000-9000-00000000000%d" % n
report = """# Should sub-agent work block the Telegram conversation?

## Summary
A Telegram message joins its bot's Home queue and is answered when that Home turn ends. A turn that spawns sub-agents ends only after `botchu-subagent wait` returns, so the chat shows "typing…" until the slowest sub-agent hands back.

### What each option changes

| | Answer first | Hold, but say so |
| :--- | :--- | :--- |
| Telegram reply | When the bot's own work is done | When every handoff is in |
| Handoffs | One follow-up message each | Inside the one reply |
| Failure modes | A handoff can arrive after you moved on | A long wait with no word |

### Evidence
1. `TelegramBridge.swift` answers when the Home turn's run ends.
2. `SubagentRuntime` keeps a caller's turn open while any child is active.
3. Three of last week's Telegram turns waited more than ten minutes.

### Recommendation
Answer first: it is how Home already hears from tasks.
"""
page = """<!doctype html><html><head><title>Providers, today and improved</title><style>
body{font:13px -apple-system,sans-serif;margin:0;background:#fff;color:#1d1d1f}
header{display:flex;justify-content:space-between;padding:14px 18px;border-bottom:1px solid #e6e6e6}
table{width:100%;border-collapse:collapse}td,th{padding:8px 18px;text-align:left;border-bottom:1px solid #f0f0f0}
.bar{height:6px;border-radius:3px;background:#e9e7ff;position:relative}.bar i{position:absolute;inset:0 auto 0 0;border-radius:3px;background:#7c5cfa}
@media (prefers-color-scheme: dark){body{background:#1c1c1e;color:#f2f2f7}header,td,th{border-color:#333}}
</style></head><body><header><b>Providers</b><span id="when"></span></header>
<table><tr><th>Provider</th><th>5-hour</th><th>Weekly</th></tr>
<tr><td>Claude Personal</td><td><div class="bar"><i style="width:30%"></i></div></td><td><div class="bar"><i style="width:68%"></i></div></td></tr>
<tr><td>Codex Work</td><td><div class="bar"><i style="width:12%"></i></div></td><td><div class="bar"><i style="width:41%"></i></div></td></tr>
<tr><td>OpenRouter</td><td><div class="bar"><i style="width:4%"></i></div></td><td><div class="bar"><i style="width:9%"></i></div></td></tr></table>
<script>document.getElementById('when').textContent='Updated just now'</script></body></html>"""
deliveries = [
  (scout, None, did(1), "Should sub-agent work block Telegram?",
   "Coder looked into [#118](https://github.com/asieke/BotChu/issues/118). Today a Telegram message is answered only when everything its turn started is back, sub-agents included, so you can watch “typing…” for as long as the slowest sub-agent takes.\n\n1. **Answer first.** The bot replies when its own work is done; each sub-agent's handoff follows as its own message.\n2. **Hold, but say so.** One reply as today, plus “Waiting on 2 sub-agents” once the wait passes a minute.\n\nI'd file the first: it's how Home already hears from tasks.",
   [("telegram-subagents.md", "document", report, {"botID": coder, "name": "Coder"})], [("asieke/BotChu", 118, False)],
   {"text": "Which should I file?", "choices": ["Answer first", "Hold, but say so"]}, [{"botID": coder, "name": "Coder"}], 28),
  (scout, task, did(2), "Providers, today and improved",
   "Done: credits, free resets and dollars now share the meter's line, and a free reset that expires within three days says when.",
   [("index.html", "page", page, None)], [], None, [], 95),
  (coder, None, did(3), "Merged 4 pull requests",
   "All four are in main, merged one at a time with the full suite green after each. **#153** is the big one: each bot's work is now reviewed once a day, and only when there's signal. Nothing is deployed.",
   [], [("asieke/BotChu", 153, True), ("asieke/BotChu", 152, True), ("asieke/BotChu", 151, True), ("asieke/BotChu", 150, True)], None, [], 64),
  (scout, None, did(4), "Grok Bot, rakazo and cleaning up workers",
   "What I found comparing the two, and what I'd clean up first.", [("comparison.md", "document", "# Grok Bot and rakazo\n\nBoth keep a bot's memory as Markdown.\n", None)],
   [], None, [], 60 * 26),
  (coder, None, did(5), "Weekly dependency check", "Nothing to update this week.", [], [], None, [], 60 * 50),
]
state = {"entries": {}}
for bot, task_id, ident, title, note, files, links, question, credits, minutes in deliveries:
    workspace = os.path.join(data, "bots", "scout" if bot == scout else "coder")
    folder = os.path.join(workspace, ".botchu", "inbox", ident.lower())
    os.makedirs(os.path.join(folder, "files"), exist_ok=True)
    listed = []
    for name, kind, text, credit in files:
        with open(os.path.join(folder, "files", name), "w") as handle: handle.write(text)
        entry = {"name": name, "kind": kind, "bytes": len(text.encode()), "source": "/tmp/" + name}
        if credit: entry["credit"] = credit
        listed.append(entry)
    record = {"id": ident, "botID": bot, "title": title, "note": note, "files": listed, "credits": credits,
              "links": [{"repo": r, "number": n, "isPullRequest": p} for r, n, p in links], "sentAt": at(minutes), "updatedAt": at(minutes)}
    if task_id: record["taskID"] = task_id
    if question: record["question"] = question
    with open(os.path.join(folder, "delivery.json"), "w") as handle: json.dump(record, handle, indent=2)
state["entries"][did(2)] = {"read": True, "done": False}
state["entries"][did(4)] = {"read": True, "done": False}
state["entries"][did(5)] = {"read": True, "done": True}
# The first one's card in Scout's Home, after the reply that announced it, and in `replied`, the
# owner's answer from the Inbox and the bot's.
thread_path = os.path.join(data, "threads", scout + ".json")
thread = json.load(open(thread_path))
thread += [
  {"id": "00000000-0000-4000-9000-000000000101", "role": "user", "date": at(40), "text": "Look into #118 with Coder, and tell me what you'd do."},
  {"id": "00000000-0000-4000-9000-000000000102", "role": "assistant", "date": at(28), "text": "Coder is back. I've put the report and my recommendation in your Inbox, with the one decision I need."},
  {"id": "00000000-0000-4000-9000-000000000103", "role": "note", "date": at(28), "text": "Delivered to your Inbox: Should sub-agent work block Telegram?", "delivery": did(1)},
]
if mode == "replied":
    thread += [
      {"id": "00000000-0000-4000-9000-000000000104", "role": "user", "date": at(5), "text": "Answer first.", "delivery": did(1)},
      {"id": "00000000-0000-4000-9000-000000000105", "role": "assistant", "date": at(4), "text": "Filing it as #156, “Answer Telegram first, then send each handoff”, with the report's table as its outcome."},
    ]
    state["entries"][did(1)] = {"read": True, "done": True, "repliedAt": at(5)}
if mode == "done":
    for item in deliveries: state["entries"][item[2]] = {"read": True, "done": True}
json.dump(thread, open(thread_path, "w"))
json.dump(state, open(os.path.join(data, "inbox.json"), "w"))
PY
fi
# Generation controls can be reviewed on any account, without sending a message or changing live settings.
python3 - "$data/bots.json" <<'PY'
import json, os, sys
from pathlib import Path
path = Path(sys.argv[1])
bots = json.loads(path.read_text())
for env, key in [('BOTCHU_ACCOUNT', 'accountID'), ('BOTCHU_MODEL', 'model'), ('BOTCHU_EFFORT', 'reasoningEffort')]:
    if env in os.environ:
        bots[0][key] = os.environ[env]
path.write_text(json.dumps(bots))
PY
"$dir/build.sh" "$data" >/dev/null
args=(--env "BOTCHU_DATA_DIR=$data" --env "BOTCHU_SNAPSHOT=$data/snapshots")
# Reports go to a stand-in gh, never to GitHub: it keeps each one in $data/reports, with the images
# it attaches, and prints a made-up issue's address, or, with BOTCHU_REPORT_FAIL=1, fails as gh does
# when it isn't signed in.
mkdir -p "$data/reports"
cat > "$data/fake-gh" <<'SH'
#!/bin/sh
dir="$(dirname "$0")/reports"
n=$(ls "$dir" | grep -c '\.md$')
printf '%s\n' "$@" > "$dir/$n.args"
cat > "$dir/$n.md"
for arg in "$@"; do
  case "$arg" in --attach=*) file=${arg#--attach=}; file=${file%%#*}; cp "$file" "$dir/$n-$(basename "$file")" ;; esac
done
if [ -e "$(dirname "$0")/fake-gh-fails" ]; then
  echo 'To get started with GitHub CLI, please run:  gh auth login' >&2
  exit 4
fi
echo "https://github.com/asieke/BotChu/issues/$((9000 + n))"
SH
chmod +x "$data/fake-gh"
[ -n "${BOTCHU_REPORT_FAIL:-}" ] && touch "$data/fake-gh-fails"
args+=(--env "BOTCHU_REPORT_GH=$data/fake-gh")
[ -n "${BOTCHU_REPORT:-}" ] && args+=(--env "BOTCHU_REPORT=$BOTCHU_REPORT")
[ -n "${BOTCHU_SCREENSHOT_FAIL:-}" ] && args+=(--env "BOTCHU_SCREENSHOT_FAIL=1")
[ -n "${BOTCHU_OPEN:-}" ] && args+=(--env "BOTCHU_OPEN=$BOTCHU_OPEN")
[ -n "${BOTCHU_TASK:-}" ] && args+=(--env "BOTCHU_TASK=$BOTCHU_TASK")
[ -n "${BOTCHU_TAB:-}" ] && args+=(--env "BOTCHU_TAB=$BOTCHU_TAB")
[ -n "${BOTCHU_TASK_REPO:-}" ] && args+=(--env "BOTCHU_TASK_REPO=$BOTCHU_TASK_REPO")
[ -n "${BOTCHU_PROJECT:-}" ] && args+=(--env "BOTCHU_PROJECT=$BOTCHU_PROJECT")
[ -n "${BOTCHU_PROJECT_TAB:-}" ] && args+=(--env "BOTCHU_PROJECT_TAB=$BOTCHU_PROJECT_TAB")
[ -n "${BOTCHU_PROJECT_ITEM:-}" ] && args+=(--env "BOTCHU_PROJECT_ITEM=$BOTCHU_PROJECT_ITEM")
[ -n "${BOTCHU_HOST:-}" ] && args+=(--env "BOTCHU_HOST=$BOTCHU_HOST")
if [ -n "${BOTCHU_FAKE_HOST:-}" ]; then
  # A host whose ssh skips its options and the host, then runs the command here, as the host would.
  mkdir -p "$data/far"
  git clone -q "$data/origin/hello-world.git" "$data/far/hello-world"
  cat > "$data/fake-ssh" <<'SH'
#!/bin/sh
while [ $# -gt 0 ]; do
  case $1 in -o|-p|-i|-l|-F) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift
exec /bin/sh -c "$*"
SH
  chmod +x "$data/fake-ssh"
  args+=(--env "BOTCHU_SSH=$data/fake-ssh" --env "BOTCHU_HOST=Far Mac|far-mac|$data/far|far-mac")
fi
[ -n "${BOTCHU_PET:-}" ] && args+=(--env "BOTCHU_PET=$BOTCHU_PET")
[ -n "${BOTCHU_DRAW_PET:-}" ] && args+=(--env "BOTCHU_DRAW_PET=$BOTCHU_DRAW_PET")
[ -n "${BOTCHU_APPEARANCE:-}" ] && args+=(--env "BOTCHU_APPEARANCE=$BOTCHU_APPEARANCE")
[ -n "${BOTCHU_USAGE:-}" ] && args+=(--env "BOTCHU_USAGE=$BOTCHU_USAGE")
[ -n "${BOTCHU_PROFILE:-}" ] && args+=(--env "BOTCHU_PROFILE=$BOTCHU_PROFILE")
[ -n "${BOTCHU_DEFAULT_MODEL:-}" ] && args+=(--env "BOTCHU_DEFAULT_MODEL=$BOTCHU_DEFAULT_MODEL")
[ -n "${BOTCHU_WINDOW:-}" ] && args+=(--env "BOTCHU_WINDOW=$BOTCHU_WINDOW")
[ -n "${BOTCHU_DEMO:-}" ] && args+=(--env "BOTCHU_DEMO=$BOTCHU_DEMO")
[ -n "${BOTCHU_DENSITY:-}" ] && args+=(--env "BOTCHU_DENSITY=$BOTCHU_DENSITY")
[ -n "${BOTCHU_SECTION:-}" ] && args+=(--env "BOTCHU_SECTION=$BOTCHU_SECTION")
[ -n "${BOTCHU_DRAFT:-}" ] && args+=(--env "BOTCHU_DRAFT=$BOTCHU_DRAFT")
[ -n "${BOTCHU_TYPE:-}" ] && args+=(--env "BOTCHU_TYPE=$BOTCHU_TYPE")
[ -n "${BOTCHU_SEARCH:-}" ] && args+=(--env "BOTCHU_SEARCH=$BOTCHU_SEARCH")
[ -n "${BOTCHU_JOBS:-}" ] && args+=(--env "BOTCHU_JOBS=$BOTCHU_JOBS")
[ -n "${BOTCHU_JOB:-}" ] && args+=(--env "BOTCHU_JOB=$BOTCHU_JOB")
[ -n "${BOTCHU_INBOX_ITEM:-}" ] && args+=(--env "BOTCHU_INBOX_ITEM=$BOTCHU_INBOX_ITEM")
[ -n "${BOTCHU_SETTINGS:-}" ] && args+=(--env "BOTCHU_SETTINGS=$BOTCHU_SETTINGS")
[ $# -gt 0 ] && args+=(--env "BOTCHU_SEND=$1")
# Without restoring windows: after any copy of BotChu crashed, macOS would otherwise stop at a
# dialog asking whether to reopen them.
open -g -n "$data/BotChu.app" "${args[@]}" --args -ApplePersistenceIgnoreState YES
echo "$data/snapshots"
