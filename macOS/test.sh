#!/usr/bin/env bash
# Build outside the gate; only prebuilt window tests acquire the shared gate.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
test_root=$(dirname "$dir")
source "$test_root/scripts/test-support.sh"
mode=${1:-full}
case "$mode" in full|--fast|--changed|--build|--prebuilt|--windows) ;; *) echo "usage: macOS/test.sh [--fast|--changed]" >&2; exit 2 ;; esac
[ $# -le 1 ] || exit 2
if { [ "$mode" = full ] || [ "$mode" = --prebuilt ] || [ "$mode" = --changed ]; } && test_inside_gate; then
  echo "test: run macOS/test.sh directly; only its --windows phase belongs inside the gate" >&2
  exit 2
fi
if [ "$mode" != --windows ] && [ "${BOTCHU_WINDOWLESS_ROOT:-}" != "$test_root" ]; then
  exec "$test_root/scripts/coord/botchu-windowless.sh" "$dir/test.sh" "$@"
fi
test_begin "macOS $mode"
trap 'test_end $?' EXIT
renderer_checksums() { (cd "$dir/Sources/BotChu/Resources/ChatRenderer" && shasum -a 256 -c SHA256SUMS --status); }
release_scratch="$dir/.build/release-tests"
release_build() {
  # `swift build --build-tests -c release` does not enable @testable imports on Xcode's
  # build system. Listing tests builds them with testability but executes no test body.
  local result
  if swift test --package-path "$dir" --configuration release --scratch-path "$release_scratch" list > "$BOTCHU_TEST_RESULTS/release-build.log" 2>&1; then result=0; else result=$?; fi
  if [ "$result" = 0 ]; then
    grep 'Build complete!' "$BOTCHU_TEST_RESULTS/release-build.log" || true
  else
    cat "$BOTCHU_TEST_RESULTS/release-build.log"
  fi
  return "$result"
}
click_test=conversationColumnSwitchesClosesAndCollapsesByNativeClicks
if [ "$mode" = --windows ]; then
  # BOTCHU_WINDOW_TESTS: a --filter of the window tests to run, and whether the click test runs.
  windows=${BOTCHU_WINDOW_TESTS:-BotChuRenderingTests} clicks=${BOTCHU_CLICK_TEST:-1}
  if [ "$windows" != none ]; then
    test_step 'window tests' test_run windows --skip-build --filter "$windows" --skip "$click_test"
  fi
  if [ "$clicks" = 1 ]; then
    test_step 'native clicks' test_run clicks --skip-build --filter "$click_test"
  fi
  if [ "${BOTCHU_RELEASE_SECRET:-0}" = 1 ]; then
    test_step 'release secure input' test_run release-secret --skip-build --configuration release --scratch-path "$release_scratch" --filter 'BotChuRenderingTests.RenderingTests/sensitiveInput'
  fi
  exit
fi
test_step 'renderer checksums' renderer_checksums
if [ "$mode" != --prebuilt ]; then
  test_step 'debug test build' swift build --package-path "$dir" --build-tests
  if [ "$mode" = full ] || [ "$mode" = --build ]; then
    test_step 'release test build' release_build
  fi
fi
[ "$mode" != --build ] || exit 0
if [ "$mode" = --fast ] || [ "$mode" = --changed ]; then
  test_step 'core tests' test_run core --skip-build --filter BotChuCoreTests
else
  test_step 'core tests' test_run core --skip-build --filter BotChuCoreTests --skip RunEvaluationTests
fi
[ "$mode" != --fast ] || exit 0
windows=BotChuRenderingTests clicks=1 release=1
if [ "$mode" = --changed ]; then
  # Only what the change can reach (scripts/test-select.py); deploy still runs everything.
  selection=$(python3 "$test_root/scripts/test-select.py" --explain --alone "$click_test")
  windows=$(sed -n 1p <<< "$selection")
  [ "$windows" != all ] || windows=BotChuRenderingTests
  if grep -qx alone <<< "$selection"; then clicks=1; else clicks=0; fi
  if grep -qx release <<< "$selection"; then release=1; else release=0; fi
  echo "test: window tests: $windows; native clicks: $clicks; release tests: $release"
  if [ "$release" = 1 ]; then test_step 'release test build' release_build; fi
fi
# Optimization is required to catch Swift 6.4's task-group regression.
if [ "$release" = 1 ]; then
  test_step 'release tests' test_run release --skip-build --configuration release --scratch-path "$release_scratch" --filter 'projectLoading|RunEvaluationTests|BotChuCoreTests.SensitiveInputTests/'
fi
[ "$windows" != none ] || [ "$clicks" = 1 ] || [ "$release" = 1 ] || exit 0
"$test_root/scripts/coord/install.sh"
run_windows() {
  local gate=/tmp/botchu-coord/gate.sh id run result
  id=$("$gate" start env BOTCHU_TEST_RESULTS="$BOTCHU_TEST_RESULTS" BOTCHU_TEST_REPORT_OWNER="$BOTCHU_TEST_REPORT_OWNER" BOTCHU_WINDOW_TESTS="$windows" BOTCHU_CLICK_TEST="$clicks" BOTCHU_RELEASE_SECRET="$release" "$dir/test.sh" --windows)
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
