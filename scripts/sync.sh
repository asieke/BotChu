#!/usr/bin/env bash
# Sync to origin/main, then optionally run a command: scripts/sync.sh [command...]
# Live checkout (this host's path in PROJECT.md's deploy field, as `scripts/deploy.sh --path` prints it):
# runs deploy.sh; if that refuses, exits 1 and runs nothing. In a project whose deploy.sh sets
# DEPLOY_ON_REQUEST=1, that run only fetches and reports what origin/main has that is not live yet.
# Any other checkout, including a task worktree: reports how far it is behind origin/main.
# Then both remove task worktrees whose pull request merged (scripts/worktree.sh --tidy) and link the
# live .env into worktrees that lack it. Never stashes, resets, or deletes work.
#   scripts/sync.sh --inspect   fetches origin and reports this checkout's state, and what a full sync
#                               would do, without deploying, switching branches, or changing any file.
#                               The SessionStart hook runs this (in a claude --worktree session, the
#                               worktree's own copy); live-app operations and scheduled jobs still need
#                               a full sync first.
set -euo pipefail
start="$PWD"
here="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$here"
live="$(cd "$(scripts/deploy.sh --path)" 2>/dev/null && pwd -P || true)"
# Whether the live checkouts deploy only on request (read from deploy.sh, never by running it).
on_request=; ! grep -qx 'DEPLOY_ON_REQUEST=1' scripts/deploy.sh 2>/dev/null || on_request=1

inspect() {
  local branch dirty ahead behind why=
  echo "sync: inspecting only; nothing is deployed, switched, or changed."
  git fetch --quiet origin 2>/dev/null || echo "sync: could not fetch origin; comparing with the last fetched origin/main."
  branch=$(git symbolic-ref --short -q HEAD || echo "detached HEAD")
  dirty=$(git --no-optional-locks status --porcelain | wc -l | tr -d ' ')
  read -r ahead behind < <(git rev-list --left-right --count HEAD...origin/main)
  echo "sync: $here is on $branch at $(git rev-parse --short HEAD): $dirty changed or untracked file(s), $ahead commit(s) not on origin/main, $behind behind it."
  if [ "$here" = "$live" ]; then
    [ "$branch" = main ] || why="not on main"
    [ "$dirty" -eq 0 ] || why="${why:+$why, }local edits"
    [ "$ahead" -eq 0 ] || why="${why:+$why, }commits not on origin/main"
    if [ -n "$why" ]; then
      echo "sync: a full sync would REFUSE ($why). Live-app operations and scheduled jobs are blocked until the owner resolves it; reviewing a pull request is not."
    elif [ "$behind" -gt 0 ] && [ -n "$on_request" ]; then
      echo "sync: origin/main is $behind commit(s) ahead of the live app, which deploys only on request: a full sync reports it, and scripts/deploy.sh deploys it."
    elif [ "$behind" -gt 0 ]; then
      echo "sync: a full sync would deploy $behind commit(s) from origin/main."
    else
      echo "sync: the live app is at origin/main."
    fi
  else
    echo "sync: not the live checkout${live:+ ($live)}. Start new work from fresh origin/main (scripts/worktree.sh); a pull request under review needs no rebase just because main moved."
  fi
  git worktree list | tail -n +2 | sed 's/^/sync: worktree /'
  echo "sync: before running, restarting, or deploying the app, using its live data, or running a scheduled job, run scripts/sync.sh (full sync) and stop if it reports REFUSED."
}

if [ "${1:-}" = --inspect ]; then
  [ $# -eq 1 ] || { echo "sync: --inspect runs no command; use scripts/sync.sh <command> to sync first" >&2; exit 2; }
  inspect
  exit 0
fi
if [ "$here" = "$live" ]; then
  if ! out=$(DEPLOY_SYNC=1 scripts/deploy.sh 2>&1); then
    printf '%s\n' "$out" "sync: REFUSED: $here could not be synced to origin/main. STOP: do not run, edit, stash, reset, commit, or delete anything here; report this output to the owner." >&2
    git status --short --branch >&2
    exit 1
  fi
  [ -z "$out" ] || echo "$out"
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then
    echo "sync: $here is at origin/main ($(git rev-parse --short HEAD)). OK to proceed."
  else
    echo "sync: $here stays at $(git rev-parse --short HEAD), what is live, since it deploys only on request. OK to proceed."
  fi
elif git fetch --quiet origin main 2>/dev/null; then
  behind=$(git rev-list --count HEAD..origin/main)
  if [ "$behind" -eq 0 ]; then echo "sync: up to date with origin/main."
  else echo "sync: $behind commit(s) behind origin/main; start from fresh origin/main or rebase before changing anything."; fi
else
  echo "sync: could not fetch origin; fetch before changing anything."
fi
# Run from the caller's directory, so tidy never removes the worktree a session is working in.
(cd "$start" 2>/dev/null || :; "$here/scripts/worktree.sh" --tidy) || echo "sync: could not tidy worktrees; run scripts/worktree.sh --tidy" >&2
scripts/worktree.sh --env || echo "sync: could not link .env into worktrees; run scripts/worktree.sh --env" >&2
[ $# -eq 0 ] || exec "$@"
