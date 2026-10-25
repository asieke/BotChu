#!/usr/bin/env bash
# Everything BotChu tests: shell syntax, the unit and rendering tests, and a build into a throwaway
# folder (so it never touches an installed or running copy). Needs full Xcode. On a Mac where other
# agents test too, run it through the shared test gate: /tmp/botchu-coord/gate.sh start scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Fails fast when xcode-select points at the Command Line Tools instead of Xcode.app.
xcodebuild -version

# Shell syntax for every script in the repository.
git ls-files -z '*.sh' | xargs -0 -n1 bash -n

# The app's scripts (README.md under Architecture) exist and are executable.
for f in macOS/build.sh macOS/install.sh macOS/test.sh; do
  [ -x "$f" ] || { echo "$f must exist and be executable" >&2; exit 1; }
done

echo "test: testing macOS"
macOS/test.sh

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
echo "test: building macOS"
macOS/build.sh "$out"
echo "test: ok"
