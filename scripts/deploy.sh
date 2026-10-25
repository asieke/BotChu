#!/usr/bin/env bash
# Deploys BotChu on this Mac, in ~/Desktop/WORKSPACE/BotChu: tests it, installs it into ~/Applications
# and smoke-tests it (README, Deploy). --skip-tests leaves out macOS/test.sh; the install's smoke test
# still runs.
set -euo pipefail
cd "$(dirname "$0")/.."
skip_tests=false
for arg in "$@"; do
  case "$arg" in
    --skip-tests) skip_tests=true ;;
    *) echo "usage: scripts/deploy.sh [--skip-tests]" >&2; exit 2 ;;
  esac
done
# Deploys only what is merged: a clean main, fast-forwarded to origin/main, runs the version that arrived.
[ "$(git branch --show-current)" = main ] && [ -z "$(git status --porcelain)" ] \
  || { echo "deploy: needs a clean checkout of main" >&2; exit 1; }
if [ -z "${DEPLOY_UPDATED:-}" ]; then
  DEPLOY_FROM=$(git rev-parse HEAD)
  git fetch --quiet origin main
  git merge --quiet --ff-only --no-overwrite-ignore origin/main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "deploy: main has commits that are not on origin/main; deploy only what is merged" >&2; exit 1; }
  DEPLOY_UPDATED=1 DEPLOY_FROM=$DEPLOY_FROM exec scripts/deploy.sh "$@"
fi
unset DEPLOY_UPDATED; export DEPLOY_FROM   # the commit that was here before this deploy
# Every attempt appends `<UTC time> <commit> ok|failed` to .git/deploys, which GitChu reads.
trap 'rc=$?; echo "$(date -u +%FT%TZ) $(git rev-parse HEAD) $([ $rc -eq 0 ] && echo ok || echo failed)" >>"$(git rev-parse --git-path deploys)"' EXIT
# Restarting BotChu stops every turn under way: deploy only when the owner asks and no turns run.
if [ "$skip_tests" = true ]; then
  echo "deploy: skipping macOS/test.sh (--skip-tests)"
else
  macOS/test.sh
fi
macOS/install.sh
