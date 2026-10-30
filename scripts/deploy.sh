#!/usr/bin/env bash
# Deploys BotChu on this Mac, in ~/Desktop/WORKSPACE/BotChu: tests it, installs it into ~/Applications
# and smoke-tests it (README, Deploy). The full suite (scripts/test.sh: Core and its Release subset,
# the kept window tests and every journey) runs unless this tree already passed it; --tests forces it
# and --skip-tests bypasses it explicitly. The install's smoke test always runs.
set -euo pipefail
cd "$(dirname "$0")/.."
test_mode=auto
for arg in "$@"; do
  case "$arg" in
    --skip-tests|--tests)
      [ "$test_mode" = auto ] || { echo "deploy: choose only one of --skip-tests and --tests" >&2; exit 2; }
      test_mode=$arg ;;
    *) echo "usage: scripts/deploy.sh [--skip-tests|--tests]" >&2; exit 2 ;;
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
source scripts/test-passes.sh
if [ "$test_mode" = --skip-tests ]; then
  echo "deploy: skipping the full suite (--skip-tests)"
elif [ "$test_mode" != --tests ] && test_tree_passed; then
  echo "deploy: skipping the full suite: it already passed for tree $(git rev-parse 'HEAD^{tree}')"
else
  echo "deploy: running full tests ($test_mode)"
  scripts/test.sh
fi
# The latency report reaches the Inbox before the install restarts BotChu; it never stops a deploy. It
# reports the journeys the full suite ran on this commit, running them itself when none did.
scripts/deploy-report.sh || echo "deploy: no latency report (exit $?)"
macOS/install.sh
