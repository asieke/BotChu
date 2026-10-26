#!/usr/bin/env bash
# Run the core unit tests and isolated WebKit rendering tests. Needs full Xcode.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
test_root=$(dirname "$dir")
source "$test_root/scripts/test-support.sh"
test_begin macOS
trap 'test_end $?' EXIT
renderer_checksums() { (cd "$dir/Sources/BotChu/Resources/ChatRenderer" && shasum -a 256 -c SHA256SUMS --status); }
test_step 'renderer checksums' renderer_checksums
test_step 'core tests' test_run core --filter BotChuCoreTests
# Native clicks leave AppKit animation state: keep their assertions in a separate process.
click_test=conversationColumnSwitchesClosesAndCollapsesByNativeClicks
test_step 'window tests' test_run windows --filter BotChuRenderingTests --skip "$click_test"
test_step 'native clicks' test_run clicks --filter "$click_test"
# Optimization is required to catch Swift 6.4's task-group regression.
test_step 'release tests' test_run release --configuration release --filter 'projectLoading|RunEvaluationTests'
