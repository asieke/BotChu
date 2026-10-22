#!/usr/bin/env bash
# Lint, typecheck and test, after the standard gate (scripts/gate.sh: hygiene and secret scan).
# Run it before pushing; `scripts/check.sh --report` also posts the "check" status that merging requires.
# It must pass from a fresh checkout, because scripts/verify-pr.sh runs it in one.
set -euo pipefail
. "$(dirname "$0")/gate.sh" "$@"
# Replace with exact commands for this stack (install dependencies first). Keep them exact: agents run this blind.
echo "scripts/check.sh: no commands yet. Add lint, typecheck and test for this stack." >&2
exit 1
