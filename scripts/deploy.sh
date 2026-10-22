#!/usr/bin/env bash
# Deploy this host's part of the app: install, restart, and smoke test. Idempotent; usually run through
# scripts/sync.sh. scripts/live.sh (sourced first, identical in every project) finds this host's live
# checkout in PROJECT.md's deploy field, refuses anything unsafe, fast-forwards it to origin/main, and
# returns here only when there is something to deploy: new commits, or any argument (--force deploys
# anyway). HOST, CANONICAL_PATH, and DEPLOY_FROM (the commit before this run) are set. To deploy only
# when someone runs this script, never at a sync or from cron, add the line DEPLOY_ON_REQUEST=1 before
# sourcing live.sh. live.sh records every attempt in .git/deploys.
set -euo pipefail
# Installing restarts BotChu, which stops any bot mid-turn, so only a direct run deploys.
DEPLOY_ON_REQUEST=1
. "$(dirname "$0")/live.sh" "$@"
# Test, then build into ~/Applications, restart BotChu if it was open, and smoke-test that it starts.
"$CANONICAL_PATH/macOS/test.sh"
"$CANONICAL_PATH/macOS/install.sh"
