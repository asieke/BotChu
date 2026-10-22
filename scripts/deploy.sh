#!/usr/bin/env bash
# Deploy this host's part of the app: install, restart, and smoke test. Idempotent; usually run through
# scripts/sync.sh. scripts/live.sh (sourced first, identical in every project) finds this host's live
# checkout in PROJECT.md's deploy field, refuses anything unsafe, fast-forwards it to origin/main, and
# returns here only when there is something to deploy: new commits, or any argument (--force deploys
# anyway). HOST, CANONICAL_PATH, and DEPLOY_FROM (the commit before this run) are set. To deploy only
# when someone runs this script, never at a sync or from cron, add the line DEPLOY_ON_REQUEST=1 before
# sourcing live.sh. live.sh records every attempt in .git/deploys.
set -euo pipefail
. "$(dirname "$0")/live.sh" "$@"
# Replace with the exact install, restart, and smoke-test commands for this host, for example:
#   npm ci --omit=dev
#   systemctl --user restart my-app
#   curl -fsS http://127.0.0.1:8080/health >/dev/null
# On several hosts, give each host its own branch of case "$HOST" (STANDARD.md, Deploy).
echo "deploy: no commands yet. Add this host's install, restart, and smoke test to scripts/deploy.sh." >&2
exit 1
