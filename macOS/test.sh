#!/usr/bin/env bash
# Run the core unit tests and isolated WebKit rendering tests. Needs full Xcode.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
(cd "$dir/Sources/BotChu/Resources/ChatRenderer" && shasum -a 256 -c SHA256SUMS --status)
# SwiftPM can return success after a test bundle fails or exits before finishing. Retain the
# runner's status, run each bundle separately, and require a successful completion summary.
test_output=$(mktemp)
trap 'rm -f "$test_output"' EXIT
run_tests() {
  swift test --package-path "$dir" "$@" 2>&1 | tee "$test_output" | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]| started\.$' || true; }
  if grep -Eq 'Some test targets reported failures:|Test run with .* failed after|Test .* failed after .* issue' "$test_output"; then
    echo "test: a test target reported failures" >&2
    return 1
  fi
  if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed after' "$test_output"; then
    echo "test: the test bundle did not finish successfully" >&2
    return 1
  fi
}
run_tests --filter BotChuCoreTests
# Native clicks on the tasks' column can leave a window-animation callback that stops Swift's
# outer run loop in a later test. Keep every native-click assertion, but contain that global
# AppKit state in its own process. Neither invocation may omit its completion summary.
click_test=conversationColumnSwitchesClosesAndCollapsesByNativeClicks
run_tests --filter BotChuRenderingTests --skip "$click_test"
run_tests --filter "$click_test"
# The Swift 6.4 task-group regression only appears under optimization; a release build alone
# cannot detect lost results or children completing after their group has been destroyed.
run_tests --configuration release --filter "projectLoading|RunEvaluationTests"
