#!/usr/bin/env bash
# Build outside the gate; only prebuilt window tests acquire the shared gate.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
test_root=$(dirname "$dir")
mode=${1:-full}
case "$mode" in full|--fast|--build|--prebuilt|--windows) ;; *) echo "usage: macOS/test.sh [--fast]" >&2; exit 2 ;; esac
[ $# -le 1 ] || exit 2
if [ "$mode" != --windows ] && [ "${BOTCHU_WINDOWLESS_ROOT:-}" != "$test_root" ]; then
  exec "$test_root/scripts/coord/botchu-windowless.sh" "$dir/test.sh" "$@"
fi
source "$test_root/scripts/test-support.sh"
test_begin "macOS $mode"
trap 'test_end $?' EXIT
renderer_checksums() { (cd "$dir/Sources/BotChu/Resources/ChatRenderer" && shasum -a 256 -c SHA256SUMS --status); }
click_test=conversationColumnSwitchesClosesAndCollapsesByNativeClicks
if [ "$mode" = --windows ]; then
  test_step 'window tests' test_run windows --skip-build --filter BotChuRenderingTests --skip "$click_test"
  test_step 'native clicks' test_run clicks --skip-build --filter "$click_test"
  exit
fi
test_step 'renderer checksums' renderer_checksums
if [ "$mode" != --prebuilt ]; then
  test_step 'debug test build' swift build --package-path "$dir" --build-tests
  if [ "$mode" != --fast ]; then
    test_step 'release test build' swift build --package-path "$dir" --configuration release --build-tests
  fi
fi
[ "$mode" != --build ] || exit 0
test_step 'core tests' test_run core --skip-build --filter BotChuCoreTests
[ "$mode" != --fast ] || exit 0
# Optimization is required to catch Swift 6.4's task-group regression.
test_step 'release tests' test_run release --skip-build --configuration release --filter 'projectLoading|RunEvaluationTests'
"$test_root/scripts/coord/install.sh"
run_windows() {
  local gate=/tmp/botchu-coord/gate.sh id run result
  id=$("$gate" start env BOTCHU_TEST_RESULTS="$BOTCHU_TEST_RESULTS" BOTCHU_TEST_REPORT_OWNER="$BOTCHU_TEST_REPORT_OWNER" "$dir/test.sh" --windows)
  run="/tmp/botchu-coord/gate/runs/$id"
  echo "test: queued window tests as $id"
  while :; do
    if "$gate" wait "$id" 30 > /dev/null; then result=0; else result=$?; fi
    [ "$result" = 75 ] || break
    echo "test: window run $id: $(cat "$run/state")"
  done
  cat "$run/log"
  if [ -f "$run/finished-at" ]; then
    echo "test: gate wait $(( $(cat "$run/started-at") - $(cat "$run/queued-at") ))s; window hold $(( $(cat "$run/finished-at") - $(cat "$run/started-at") ))s"
  fi
  return "$result"
}
test_step 'gated window tests' run_windows
