# Standard deploy preamble, sourced first by every scripts/deploy.sh:  . "$(dirname "$0")/live.sh" "$@"
#   scripts/deploy.sh           in this host's live checkout: refuses unless it is a clean checkout of
#                               main with no commits missing from origin/main, fast-forwards it to
#                               origin/main, and reruns deploy.sh from the version that arrived, which
#                               then goes on to its own install, restart, and smoke test. When nothing
#                               changed, it exits here instead.
#   scripts/deploy.sh <args>    the same, but deploys even when nothing changed (--force, or any
#                               argument the project's deploy.sh defines; the arguments stay in "$@")
#   scripts/deploy.sh --path    prints this host's live checkout, or /dev/null on a host that deploy does
#                               not list, where nothing is live (scripts/sync.sh asks this)
# This host's live checkout is the path of the local:<host>:<path> entry in PROJECT.md's deploy field
# whose host is this machine's short name, so hosts and paths are written only there. It refuses on an
# unlisted host and from any other checkout. For the rest of deploy.sh it sets HOST (this machine's
# short name), CANONICAL_PATH (the live checkout, now the current directory), and DEPLOY_FROM
# (exported: the commit the checkout was on before this run). A deploy.sh that can have work pending
# when nothing changed (such as an iPhone install that waited for the phone) defines deploy_pending
# before sourcing this, returning true while that work is pending.
# A project whose live checkouts deploy only on request sets DEPLOY_ON_REQUEST=1 (that line, alone) before
# sourcing this. Run by scripts/sync.sh (which sets DEPLOY_SYNC=1), it then fetches and reports how far
# origin/main is ahead of what is live, after the same refusals, and changes nothing; run directly, it
# deploys as usual.
# Every deploy attempt appends one line to the deploy record, `deploys` in the live checkout's git
# directory (.git/deploys): its UTC time, the commit, and ok (deploy.sh's install, restart, and smoke
# test passed) or failed. What is live on this host is the commit of its last ok line.
# Identical in every project: copy it from asieke/workspace templates/local/scripts/live.sh; do not edit.
# deploy.sh must not set its own EXIT trap: this one logs each deploy that succeeds.

# This machine's short name, as deploy lists it: a Mac's LocalHostName (its hostname can change with
# the network), otherwise the hostname up to the first dot.
HOST=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || uname -n); HOST=${HOST%%.*}
live_project="$(dirname "${BASH_SOURCE[0]}")/../PROJECT.md"
[ -f "$live_project" ] || { echo "deploy: no PROJECT.md beside scripts/, refusing" >&2; exit 1; }
# The path of this host's entry in the frontmatter's deploy line, with ~/ for $HOME/.
CANONICAL_PATH=$(awk -v h="$HOST" '
  NR == 1 && $0 != "---" { exit }
  NR > 1 && $0 == "---" { exit }
  NR > 1 && index($0, "deploy:") == 1 {
    v = substr($0, 8); sub(/[ \t]*#.*$/, "", v)
    n = split(v, e, ",")
    for (i = 1; i <= n; i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", e[i])
      if (index(e[i], "local:" h ":") == 1) { print substr(e[i], length(h) + 8); exit }
    }
    exit
  }' "$live_project")
case "$CANONICAL_PATH" in
  "~/"*) CANONICAL_PATH="$HOME/${CANONICAL_PATH#"~/"}" ;;
  /*) ;;
  *) CANONICAL_PATH=/dev/null ;;
esac
[ "${1:-}" != --path ] || { echo "$CANONICAL_PATH"; exit 0; }
[ "$CANONICAL_PATH" != /dev/null ] || { echo "deploy: $HOST is not a deploy host in PROJECT.md, refusing" >&2; exit 1; }
[ "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" = "$(cd "$CANONICAL_PATH" 2>/dev/null && pwd -P)" ] \
  || { echo "deploy: run this from $CANONICAL_PATH, the live checkout on $HOST; refusing" >&2; exit 1; }
cd "$CANONICAL_PATH"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "deploy: not on main, refusing" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "deploy: dirty tree, refusing" >&2; exit 1; }
if [ -n "${DEPLOY_UPDATED:-}" ]; then
  # Rerun below by the version that was here before the fast-forward. One whose deploy.sh predates this
  # file set no DEPLOY_FROM, so take the commit before its merge from the reflog.
  unset DEPLOY_UPDATED
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "deploy: not at origin/main after fast-forwarding, refusing" >&2; exit 1; }
  DEPLOY_FROM=${DEPLOY_FROM:-$(git rev-parse -q --verify 'HEAD@{1}' || git rev-parse HEAD)}
else
  git fetch --quiet origin main
  DEPLOY_FROM=$(git rev-parse HEAD)
  if [ "${DEPLOY_SYNC:-}" = 1 ] && [ "${DEPLOY_ON_REQUEST:-}" = 1 ]; then
    # A sync (or a cron job through it) of a project that deploys only on request: report, change nothing.
    git merge-base --is-ancestor HEAD origin/main \
      || { echo "deploy: local commits not on origin/main, refusing; push them to a branch and open a PR" >&2; exit 1; }
    live_behind=$(git rev-list --count HEAD..origin/main)
    [ "$live_behind" -eq 0 ] \
      || echo "deploy: origin/main is $live_behind commit(s) ahead of $(git rev-parse --short HEAD) on $HOST, which deploys only on request: run scripts/deploy.sh to deploy it"
    exit 0
  fi
  if [ "$DEPLOY_FROM" = "$(git rev-parse origin/main)" ]; then
    # Nothing new: deploy only when asked to (any argument) or when deploy.sh has work pending.
    [ $# -gt 0 ] || { declare -F deploy_pending >/dev/null && deploy_pending; } || exit 0
  else
    # --ff-only alone succeeds when HEAD is ahead of origin/main, so also require HEAD to be an ancestor.
    git merge-base --is-ancestor HEAD origin/main \
      || { echo "deploy: local commits not on origin/main, refusing; push them to a branch and open a PR" >&2; exit 1; }
    # Never replace an ignored file, such as .env, with one that main has started to track.
    git merge --ff-only --no-overwrite-ignore --quiet origin/main \
      || { echo "deploy: could not fast-forward to origin/main without overwriting the files above, refusing" >&2; exit 1; }
    # Run the rest from the version of deploy.sh (and of this file) that just arrived, with the same arguments.
    DEPLOY_UPDATED=1 DEPLOY_FROM="$DEPLOY_FROM" exec "$CANONICAL_PATH/scripts/deploy.sh" "$@"
  fi
fi
export DEPLOY_FROM
# The deploy record (see above), written when deploy.sh ends: ok only once its smoke test has passed.
live_record=$(cd "$(git rev-parse --git-path deploys | sed 's|/deploys$||')" && pwd -P)/deploys
live_end() {
  local rc=$1 at head
  at=$(date -u +%FT%TZ) head=$(git -C "$CANONICAL_PATH" rev-parse HEAD)
  if [ "$rc" -eq 0 ]; then
    echo "$at $head ok" >>"$live_record"
    echo "deploy: $at $(git -C "$CANONICAL_PATH" rev-parse --short HEAD) on $HOST"
    if declare -F deploy_pending >/dev/null && deploy_pending; then
      echo "deploy: part of this deploy is still pending; a later scripts/deploy.sh finishes it"
    fi
  else
    echo "$at $head failed" >>"$live_record"
  fi
}
trap 'live_rc=$?; live_end "$live_rc" || :; exit $live_rc' EXIT
