#!/usr/bin/env bash
# Open a freshly built BotChu on throwaway data, so its screens can be checked without touching real
# bots or needing screen-recording permission: the app writes a PNG of each of its windows into the
# snapshot folder every second (DevHooks.swift). Two demo bots are seeded, the first (selected) with a short
# sample conversation and memory, in the layout before bot folders, so each run also migrates them, and
# two tasks in a throwaway repository.
#   macOS/ui-review.sh                     # just open it
#   macOS/ui-review.sh "Hello"             # and send "Hello" to the first bot (a real turn)
#   BOTCHU_OPEN=editor macOS/ui-review.sh  # or open the new-bot editor (or settings)
#   BOTCHU_PET=~/.codex/pets/mochi macOS/ui-review.sh  # and give the first bot this Codex pet
#   BOTCHU_DRAW_PET="a brass robot" macOS/ui-review.sh # or have Codex draw it one (takes a while)
#   BOTCHU_TAB=1 macOS/ui-review.sh        # show the first bot's first task tab (0 is Home)
#   BOTCHU_TASK="hello-world|Add a line" macOS/ui-review.sh  # start a task (a real turn on Claude Dev)
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
{"date":"2026-10-22T03:03:05Z","id":"00000000-0000-4000-8000-000000000022","role":"error","text":"Couldn't make this task's worktree. scripts/worktree.sh feat/3-fix-typo failed."}
JSON
"$dir/build.sh" "$data" >/dev/null
args=(--env "BOTCHU_DATA_DIR=$data" --env "BOTCHU_SNAPSHOT=$data/snapshots")
[ -n "${BOTCHU_OPEN:-}" ] && args+=(--env "BOTCHU_OPEN=$BOTCHU_OPEN")
[ -n "${BOTCHU_TASK:-}" ] && args+=(--env "BOTCHU_TASK=$BOTCHU_TASK")
[ -n "${BOTCHU_TAB:-}" ] && args+=(--env "BOTCHU_TAB=$BOTCHU_TAB")
[ -n "${BOTCHU_PET:-}" ] && args+=(--env "BOTCHU_PET=$BOTCHU_PET")
[ -n "${BOTCHU_DRAW_PET:-}" ] && args+=(--env "BOTCHU_DRAW_PET=$BOTCHU_DRAW_PET")
[ -n "${BOTCHU_APPEARANCE:-}" ] && args+=(--env "BOTCHU_APPEARANCE=$BOTCHU_APPEARANCE")
[ -n "${BOTCHU_USAGE:-}" ] && args+=(--env "BOTCHU_USAGE=$BOTCHU_USAGE")
[ $# -gt 0 ] && args+=(--env "BOTCHU_SEND=$1")
open -g -n "$data/BotChu.app" "${args[@]}"
echo "$data/snapshots"
