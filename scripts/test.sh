#!/usr/bin/env bash
# Everything BotChu tests: shell syntax, the unit and rendering tests, and a build into a throwaway
# folder (so it never touches an installed or running copy). Needs full Xcode. Run directly:
# only the prebuilt window phase takes the shared test gate. --fast leaves out the window tests,
# Release and the app build; --changed adds the window and Release tests the change can reach.
# --journeys [names] builds the release app and runs the journeys harness on it, in the gate.
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
  --changed) tier=changed; shift ;;
  --journeys)
    tier=journeys; shift
    if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then journeys=$1; shift; fi ;;
  *) echo "usage: scripts/test.sh [--fast|--changed|--journeys [names]]" >&2; exit 2 ;;
esac
[ $# = 0 ] || { echo "usage: scripts/test.sh [--fast|--changed|--journeys [names]]" >&2; exit 2; }
if [ "$tier" != fast ] && test_inside_gate; then
  echo "test: run scripts/test.sh directly, not inside gate.sh; it gates its own window tests" >&2
  exit 2
fi
test_begin "$tier"
out=
trap 'result=$?; [ -z "$out" ] || rm -rf "$out"; test_end "$result"' EXIT

# Fails fast when xcode-select points at the Command Line Tools instead of Xcode.app.
test_step toolchain xcodebuild -version

# The journeys (README.md, Test): a release app and the harness that drives it from outside, one
# gated run, so no window test runs beside it. BOTCHU_JOURNEYS_RECORD=1 records a new baseline.
if [ "$tier" = journeys ]; then
  out=$(mktemp -d)
  test_step 'app build' macOS/build.sh "$out"
  journeys_build() { swift build -c release --package-path macOS --scratch-path macOS/.build/app --product botchu-journeys 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' || true; }; }
  test_step 'journeys build' journeys_build
  harness="$(swift build -c release --package-path macOS --scratch-path macOS/.build/app --show-bin-path)/botchu-journeys"
  run_journeys() {
    local gate=/tmp/botchu-coord/gate.sh id run result record=()
    [ "${BOTCHU_JOURNEYS_RECORD:-0}" != 1 ] || record=(--record "$test_root/macOS/Journeys/baseline.json")
    id=$("$gate" start "$harness" --app "$out/BotChu.app" --journeys "${journeys:-all}" --baseline "$test_root/macOS/Journeys/baseline.json" ${record[@]+"${record[@]}"})
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
  test_step 'gated journeys' run_journeys
  echo "test: ok (journeys)"
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

if [ "$tier" != full ]; then
  test_step "$tier macOS tests" macOS/test.sh "--$tier"
  echo "test: ok ($tier)"
  exit
fi
test_step 'test builds' macOS/test.sh --build
out=$(mktemp -d)
test_step 'app build' macOS/build.sh "$out"
test_step 'macOS tests' macOS/test.sh --prebuilt
test_record_pass
echo "test: ok"
