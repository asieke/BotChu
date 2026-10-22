#!/usr/bin/env bash
# Run the core unit tests and isolated WebKit rendering tests. Needs full Xcode.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
(cd "$dir/Sources/BotChu/Resources/ChatRenderer" && shasum -a 256 -c SHA256SUMS --status)
# SwiftPM can return success after one test bundle fails and a later bundle passes. Retain the
# runner's status, and also reject its explicit failed-target summary instead of masking it.
test_output=$(mktemp)
trap 'rm -f "$test_output"' EXIT
run_tests() {
  swift test --package-path "$dir" "$@" 2>&1 | tee "$test_output" | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]| started\.$' || true; }
  if grep -Eq 'Some test targets reported failures:|Test run with .* failed after|Test .* failed after .* issue' "$test_output"; then
    echo "test: a test target reported failures" >&2
    return 1
  fi
}
run_tests
# The Swift 6.4 task-group regression only appears under optimization; a release build alone
# cannot detect lost results or children completing after their group has been destroyed.
run_tests --configuration release --filter projectLoading
