#!/usr/bin/env bash
# Run the core unit tests and isolated WebKit rendering tests. Needs full Xcode.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
(cd "$dir/Sources/BotChu/Resources/ChatRenderer" && shasum -a 256 -c SHA256SUMS --status)
# Only the build's errors and each test's outcome; the exit status is swift test's.
swift test --package-path "$dir" 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]| started\.$' || true; }
