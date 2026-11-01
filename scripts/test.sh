#!/usr/bin/env bash
# Everything BotChu tests (README.md, Test; docs/testing.md): shell syntax, the Core tests and their
# Release subset, the kept window tests, and the journeys on a release build with their latency
# report, building into throwaway folders so it never touches an installed or running copy. Needs
# full Xcode. Run directly: only the window tests and the journeys take the shared test gate.
# --fast leaves out Release, the window tests and the journeys; --journeys [names] runs only the
# journeys; --journeys-replica only the journeys on a copy of the replica of the owner's data
# (scripts/replica.sh), which the full suite runs too. BOTCHU_JOURNEYS_RECORD=1 records the journeys'
# times as the new baseline.
set -euo pipefail
cd "$(dirname "$0")/.."
test_root=$PWD
if [ "${BOTCHU_WINDOWLESS_ROOT:-}" != "$test_root" ]; then
  exec "$test_root/scripts/coord/botchu-windowless.sh" "$test_root/scripts/test.sh" "$@"
fi
scripts/coord/install.sh
source scripts/test-support.sh
source scripts/test-passes.sh
test_capture_tree
tier=full
journeys=
case "${1:-}" in
  '') ;;
  --fast) tier=fast; shift ;;
  --journeys)
    tier=journeys; shift
    if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then journeys=$1; shift; fi ;;
  --journeys-replica) tier=replica; shift ;;
  *) echo "usage: scripts/test.sh [--fast|--journeys [names]|--journeys-replica]" >&2; exit 2 ;;
esac
[ $# = 0 ] || { echo "usage: scripts/test.sh [--fast|--journeys [names]|--journeys-replica]" >&2; exit 2; }
if [ "$tier" != fast ] && test_inside_gate; then
  echo "test: run scripts/test.sh directly, not inside gate.sh; it gates its own window tests and journeys" >&2
  exit 2
fi
test_begin "$tier"
out=
trap 'result=$?; [ -z "$out" ] || rm -rf "$out"; test_end "$result"' EXIT

# Fails fast when xcode-select points at the Command Line Tools instead of Xcode.app.
test_step toolchain xcodebuild -version

# The journeys (README.md, Test) on the release app in $out and the harness that drives it from
# outside, one gated run, so no window test runs beside it; then the latency report of its results.
test_journeys() {
  journeys_build() { swift build -c release --package-path macOS --scratch-path macOS/.build/app --product botchu-journeys 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' || true; }; }
  test_step 'journeys build' journeys_build || return
  harness="$(swift build -c release --package-path macOS --scratch-path macOS/.build/app --show-bin-path)/botchu-journeys"
  commit=$(/usr/libexec/PlistBuddy -c 'Print :BotChuCommit' "$out/BotChu.app/Contents/Info.plist" 2>/dev/null || true)
  local runs=${journeys_runs:-${BOTCHU_JOURNEYS_RUNS:-$HOME/Library/Caches/botchu-journeys/runs}}
  results="$runs/$(date -u +%Y%m%dT%H%M%SZ)-${commit:-unknown}.json"
  run_journeys() {
    local gate=/tmp/botchu-coord/gate.sh id run result record=()
    [ "${BOTCHU_JOURNEYS_RECORD:-0}" != 1 ] || record=(--record "$test_root/macOS/Journeys/baseline.json")
    id=$("$gate" start "$harness" --app "$out/BotChu.app" --journeys "${journeys:-all}" --baseline "$test_root/macOS/Journeys/baseline.json" \
      --results "$results" --branch "$(git branch --show-current)" ${record[@]+"${record[@]}"} ${journeys_extra[@]+"${journeys_extra[@]}"})
    run="/tmp/botchu-coord/gate/runs/$id"
    echo "test: queued the journeys as $id"
    while :; do
      if "$gate" wait "$id" 30 > /dev/null; then result=0; else result=$?; fi
      [ "$result" = 75 ] || break
      echo "test: journeys run $id: $(cat "$run/state")"
    done
    cat "$run/log"
    if [ -f "$run/finished-at" ]; then
      echo "test: gate wait $(( $(cat "$run/started-at") - $(cat "$run/queued-at") ))s; journeys $(( $(cat "$run/finished-at") - $(cat "$run/started-at") ))s"
    fi
    return "$result"
  }
  local result
  if test_step 'gated journeys' run_journeys; then result=0; else result=$?; fi
  [ "$result" != 0 ] || echo "test: ok (journeys)"
  if [ -f "$results" ]; then
    BOTCHU_JOURNEYS_RUNS=$runs scripts/journeys-report.py --results "$results" --write "${results%.json}.md"
    echo "test: latency report ${results%.json}.md"
  else
    echo "test: the journeys left no results in $results"
  fi
  return "$result"
}

# The journeys on a copy of the replica (#422), which the harness makes and deletes, with their own
# history: report only until baseline.json has their steps. Without a replica there is nothing to run.
test_replica_journeys() {
  local replica=${BOTCHU_REPLICA:-$HOME/Library/Application Support/BotChu Replica}
  if [ ! -f "$replica/replica.json" ]; then
    echo "test: no replica: run scripts/replica.sh refresh"
    return 0
  fi
  scripts/replica.sh status
  local journeys_runs=${BOTCHU_JOURNEYS_REPLICA_RUNS:-$HOME/Library/Caches/botchu-journeys/replica-runs} journeys=
  local journeys_extra=(--replica "$replica")
  test_journeys
}

if [ "$tier" = journeys ] || [ "$tier" = replica ]; then
  if [ "$tier" = replica ] && [ ! -f "${BOTCHU_REPLICA:-$HOME/Library/Application Support/BotChu Replica}/replica.json" ]; then
    test_replica_journeys
    exit
  fi
  out=$(mktemp -d)
  test_step 'app build' macOS/build.sh "$out"
  if [ "$tier" = replica ]; then test_replica_journeys; else test_journeys; fi
  exit
fi

# Shell syntax for every script in the repository.
shell_syntax() { git ls-files -z '*.sh' | xargs -0 -n1 bash -n; }
test_step 'shell syntax' shell_syntax
test_step 'workflow checks' python3 -m unittest discover -s scripts/tests

# The app's scripts (README.md under Architecture) exist and are executable.
for f in macOS/build.sh macOS/install.sh macOS/test.sh; do
  [ -x "$f" ] || { echo "$f must exist and be executable" >&2; exit 1; }
done

if [ "$tier" = fast ]; then
  test_step 'fast macOS tests' macOS/test.sh --fast
  echo "test: ok (fast)"
  exit
fi
test_step 'test builds' macOS/test.sh --build
out=$(mktemp -d)
test_step 'app build' macOS/build.sh "$out"
test_step 'macOS tests' macOS/test.sh --prebuilt
if test_journeys; then result=0; else result=$?; fi
if [ "$result" = 0 ]; then
  if test_replica_journeys; then :; else result=$?; fi
fi
if [ "$result" != 0 ]; then
  echo "test: everything but the journeys passed. Run them again once the load is under 10" \
    "(scripts/test.sh --journeys <names>); scripts/deploy.sh --skip-tests deploys and still reports their latency." >&2
  exit "$result"
fi
test_record_pass
echo "test: ok"
