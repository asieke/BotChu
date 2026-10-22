#!/usr/bin/env bash
# Open a freshly built BotChu on throwaway data, so its screens can be checked without touching real
# bots or needing screen-recording permission: the app writes a PNG of each of its windows into the
# snapshot folder every second (DevHooks.swift). Two demo bots are seeded, the first (selected) with a short
# sample conversation and memory.
#   macOS/ui-review.sh                     # just open it
#   macOS/ui-review.sh "Hello"             # and send "Hello" to the first bot (a real turn)
#   BOTCHU_OPEN=editor macOS/ui-review.sh  # or open the new-bot editor (or settings)
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
  "text":"## Workspace notes\n\nI found **four files**. See the [project guide](https://example.com) for details.\n\n1. Read `AGENTS.md`\n   - It describes who I am.\n2. Keep `MEMORY.md` current.\n\n> Noted that you like short answers.\n\n| File | Purpose |\n| :--- | :--- |\n| `AGENTS.md` | Instructions |\n| `MEMORY.md` | Persistent notes |\n\n```swift\nlet answer = 42\nprint(answer)\n```"}]
JSON
printf '# Scout\n\nWhat Scout has learned and keeps across conversations.\n\n- Prefers short answers.\n- Works on BotChu, a macOS app.\n' > "$data/bots/scout/MEMORY.md"
"$dir/build.sh" "$data" >/dev/null
args=(--env "BOTCHU_DATA_DIR=$data" --env "BOTCHU_SNAPSHOT=$data/snapshots")
[ -n "${BOTCHU_OPEN:-}" ] && args+=(--env "BOTCHU_OPEN=$BOTCHU_OPEN")
[ $# -gt 0 ] && args+=(--env "BOTCHU_SEND=$1")
open -n "$data/BotChu.app" "${args[@]}"
echo "$data/snapshots"
