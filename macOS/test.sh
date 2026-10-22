#!/usr/bin/env bash
# Run BotChuCore's unit tests (stream parsers, commands, context, store). Needs full Xcode.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
# Only the build's errors and each test's outcome; the exit status is swift test's.
swift test --package-path "$dir" 2>&1 | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]| started\.$' || true; }
