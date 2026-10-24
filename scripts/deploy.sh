#!/usr/bin/env bash
# Deploy this host's part of the app: install, restart, and smoke test. Run it on the host, in its live
# checkout, to put a merged revision live; nothing else deploys. scripts/live.sh (sourced first,
# identical in every project) finds this host's live checkout in PROJECT.md's deploy field, refuses
# anything unsafe, moves it to origin/main (or DEPLOY_REV), and returns here only when there is
# something to deploy: a new revision, or any argument (--force deploys anyway). HOST, CANONICAL_PATH,
# and DEPLOY_FROM (the commit before this run) are set. live.sh records every attempt in .git/deploys.
set -euo pipefail
. "$(dirname "$0")/live.sh" "$@"
# Test, then build into ~/Applications, restart BotChu if it was open (which stops every turn under way),
# and smoke-test that it starts.
"$CANONICAL_PATH/macOS/test.sh"
"$CANONICAL_PATH/macOS/install.sh"
