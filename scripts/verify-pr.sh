#!/usr/bin/env bash
# Test a pull request on this machine and report the result as the "check" status merging requires:
#   scripts/verify-pr.sh <number>               runs `scripts/check.sh --report`, posting the status
#   scripts/verify-pr.sh --no-report <number>   runs plain `scripts/check.sh` and posts nothing, for
#                                               reviews that must not publish anything
# Checks the PR out into a temporary worktree, runs the checks there, and removes it, so the checkout
# it runs from stays on its branch untouched. Run it where the project can really be tested (for
# example, the Mac with Xcode, or a local app's host).
# Identical in every project: copy it from asieke/workspace templates/common/scripts/verify-pr.sh.
set -euo pipefail
report=--report; [ "${1:-}" != --no-report ] || { report=; shift; }
n="${1:?usage: scripts/verify-pr.sh [--no-report] <pr-number>}"
[[ "$n" =~ ^[0-9]+$ ]] && [ $# -eq 1 ] || { echo "usage: scripts/verify-pr.sh [--no-report] <pr-number>" >&2; exit 2; }
cd "$(dirname "$0")/.."
git fetch --quiet origin main
git fetch --quiet origin "pull/$n/head"
sha=$(git rev-parse FETCH_HEAD)
dir="$(mktemp -d)/pr-$n"
git worktree add --quiet --detach "$dir" "$sha"
trap 'git worktree remove --force "$dir"' EXIT
echo "verify-pr: testing PR #$n at ${sha:0:7} in $dir$([ -n "$report" ] || echo ", posting nothing")"
(cd "$dir" && scripts/check.sh $report)
