#!/usr/bin/env bash
# Open a freshly built BotChu on throwaway data, so its screens can be checked without touching real
# bots or needing screen-recording permission: the app writes a PNG of each of its windows into the
# snapshot folder every second (DevHooks.swift). Two demo bots are seeded, the first (selected) with a short
# sample conversation and memory, in the layout before bot folders, so each run also migrates them.
#   macOS/ui-review.sh                     # just open it
#   macOS/ui-review.sh "Hello"             # and send "Hello" to the first bot (a real turn)
#   BOTCHU_OPEN=editor macOS/ui-review.sh  # or open the new-bot editor (or settings)
#   BOTCHU_PET=~/.codex/pets/mochi macOS/ui-review.sh  # and give the first bot this Codex pet
#   BOTCHU_DRAW_PET="a brass robot" macOS/ui-review.sh # or have Codex draw it one (takes a while)
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
  "text":"## All three workers reported back\n\nThe ranges are $p_1 \\dots p_{1000}$, $p_{1001} \\dots p_{2000}$ and $p_{2001} \\dots p_{3000}$.\n\n| Subagent | First prime | Last prime | Sum |\n| :--- | ---: | ---: | ---: |\n| [Worker 1](https://example.com/1) | $2$ | $7,919$ | **3,682,913** |\n| Worker 2 | $7,927$ | $17,389$ | **12,591,714** |\n| Worker 3 | $17,393$ | $27,449$ | **22,370,584** |\n| **Total** | $2$ | $27,449$ | **38,645,211** |\n\n$$3,682,913 + 12,591,714 + 22,370,584 = \\mathbf{38,645,211}$$\n\n1. Each worker checked its range.\n   - No primes overlap.\n2. Added their results.\n\n> All results are ready.\n\n```swift\nlet answer = 38_645_211\nprint(answer)\n```\n\n```mermaid\nflowchart LR\n  subgraph BotChu[BotChu]\n    Chat[Chat stream]\n  end\n  subgraph Local[This Mac]\n    Worktree[Git worktree]\n  end\n  subgraph GitHub[GitHub]\n    PR[Pull request]\n  end\n  Chat -->|Spawn work| Worktree\n  Worktree -->|Push and check| PR\n  PR -->|Review| Chat\n```"}]
JSON
printf '# Scout\n\nWhat Scout has learned and keeps across conversations.\n\n- Prefers short answers.\n- Works on BotChu, a macOS app.\n' > "$data/bots/scout/MEMORY.md"
"$dir/build.sh" "$data" >/dev/null
args=(--env "BOTCHU_DATA_DIR=$data" --env "BOTCHU_SNAPSHOT=$data/snapshots")
[ -n "${BOTCHU_OPEN:-}" ] && args+=(--env "BOTCHU_OPEN=$BOTCHU_OPEN")
[ -n "${BOTCHU_PET:-}" ] && args+=(--env "BOTCHU_PET=$BOTCHU_PET")
[ -n "${BOTCHU_DRAW_PET:-}" ] && args+=(--env "BOTCHU_DRAW_PET=$BOTCHU_DRAW_PET")
[ -n "${BOTCHU_APPEARANCE:-}" ] && args+=(--env "BOTCHU_APPEARANCE=$BOTCHU_APPEARANCE")
[ $# -gt 0 ] && args+=(--env "BOTCHU_SEND=$1")
open -g -n "$data/BotChu.app" "${args[@]}"
echo "$data/snapshots"
