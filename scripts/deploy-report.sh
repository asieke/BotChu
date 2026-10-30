#!/usr/bin/env bash
# Deploy's latency report (#362; README, Deploy): runs the journeys when this commit has no results
# yet, writes the report beside the newest results and sends it to the owner's Inbox as an FYI,
# or prints its path when botchu-inbox isn't on PATH or can't send.
set -euo pipefail
cd "$(dirname "$0")/.."
runs=${BOTCHU_JOURNEYS_RUNS:-$HOME/Library/Caches/botchu-journeys/runs}
commit=$(git rev-parse --short=7 HEAD)
newest() {
  local file last=
  for file in "$runs"/*-"$commit".json; do [ ! -f "$file" ] || last=$file; done
  printf '%s' "$last"
}
results=$(newest)
if [ -z "$results" ]; then
  echo "deploy: no journeys results for $commit; running them"
  scripts/test.sh --journeys || echo "deploy: the journeys failed (exit $?); reporting what they measured"
  results=$(newest)
  [ -n "$results" ] || { echo "deploy: the journeys left no results for $commit" >&2; exit 1; }
fi
report=${results%.json}.md
scripts/journeys-report.py --results "$results" --write "$report"
if command -v botchu-inbox > /dev/null \
  && botchu-inbox send --purpose fyi --title "BotChu $commit deployed: latency report" --note "$(head -n 1 "$report")" --file "$report"; then
  echo "deploy: sent the latency report to the Inbox"
else
  echo "deploy: latency report $report"
fi
