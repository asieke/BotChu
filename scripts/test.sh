#!/usr/bin/env bash
# Everything BotChu tests: shell syntax, the unit and rendering tests, and a build into a throwaway
# folder (so it never touches an installed or running copy). Needs full Xcode. On a Mac where other
# agents test too, run it through the shared test gate: /tmp/botchu-coord/gate.sh start scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
test_root=$PWD
source scripts/test-support.sh
test_begin full
out=
trap 'result=$?; [ -z "$out" ] || rm -rf "$out"; test_end "$result"' EXIT

# Fails fast when xcode-select points at the Command Line Tools instead of Xcode.app.
test_step toolchain xcodebuild -version

# Shell syntax for every script in the repository.
shell_syntax() { git ls-files -z '*.sh' | xargs -0 -n1 bash -n; }
test_step 'shell syntax' shell_syntax

# The app's scripts (README.md under Architecture) exist and are executable.
for f in macOS/build.sh macOS/install.sh macOS/test.sh; do
  [ -x "$f" ] || { echo "$f must exist and be executable" >&2; exit 1; }
done

test_step 'macOS tests' macOS/test.sh

out=$(mktemp -d)
test_step 'app build' macOS/build.sh "$out"
echo "test: ok"
