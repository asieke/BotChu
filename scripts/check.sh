#!/usr/bin/env bash
# Lint, typecheck and test, after the standard gate (scripts/gate.sh: hygiene and secret scan).
# Run it before pushing; `scripts/check.sh --report` also posts the "check" status that merging requires.
# It must pass from a fresh checkout, because scripts/verify-pr.sh runs it in one.
set -euo pipefail
. "$(dirname "$0")/gate.sh" "$@"

# Fails fast when xcode-select points at the Command Line Tools instead of Xcode.app.
xcodebuild -version

# Shell syntax for every script in the repository.
git ls-files -z '*.sh' | xargs -0 -n1 bash -n

# The app's scripts (README.md under Architecture) exist and are executable.
for f in macOS/build.sh macOS/install.sh macOS/test.sh; do
  [ -x "$f" ] || { echo "$f must exist and be executable" >&2; exit 1; }
done

# Unit tests (the Swift package has no dependencies to install).
echo "check: testing macOS"
macOS/test.sh

# Build and sign the app into a throwaway folder, so a check never touches an installed or running
# copy. The folder is removed in a subshell's own trap: gate.sh owns check.sh's EXIT trap for --report.
(
  out=$(mktemp -d)
  trap 'rm -rf "$out"' EXIT
  echo "check: building macOS"
  macOS/build.sh "$out"
)
echo "check: ok"
