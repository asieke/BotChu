# Standard deploy preamble, sourced first by every scripts/deploy.sh:  . "$(dirname "$0")/live.sh" "$@"
# Deploying is its own operation, run on the host in its live checkout when someone wants a merged
# revision live there (or from cron, for a project whose README says it deploys automatically):
#   scripts/deploy.sh           refuses unless this is the host's live checkout, clean, on main, with no
#                               commits missing from origin/main; moves it to origin/main and reruns
#                               deploy.sh from the version that arrived, which then goes on to its own
#                               install, restart, and smoke test. When that revision is already checked
#                               out, it exits here instead.
#   scripts/deploy.sh <args>    the same, but deploys even when nothing changed (--force, or any
#                               argument the project's deploy.sh defines; the arguments stay in "$@")
#   DEPLOY_REV=<commit> scripts/deploy.sh
#                               the same for that commit of origin/main instead, such as the last good
#                               release after a failed deploy
# This host's live checkout is the path of the local:<host>:<path> entry in PROJECT.md's deploy field
# whose host is this machine's short name, so hosts and paths are written only there. It refuses on an
# unlisted host and from any other checkout. For the rest of deploy.sh it sets HOST (this machine's
# short name), CANONICAL_PATH (the live checkout, now the current directory), and DEPLOY_FROM
# (exported: the commit the checkout was on before this run). A deploy.sh that can have work pending
# when nothing changed (such as an iPhone install that waited for the phone) defines deploy_pending
# before sourcing this, returning true while that work is pending.
# Every deploy attempt appends one line to the deploy record, `deploys` in the live checkout's git
# directory (.git/deploys): its UTC time, the commit, and ok (deploy.sh's install, restart, and smoke
# test passed) or failed. What is live on this host is the commit of its last ok line.
# Identical in every project: copy it from asieke/workspace templates/local/scripts/live.sh; do not edit.
# deploy.sh must not set its own EXIT trap: this one records each attempt.

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
  *) echo "deploy: $HOST is not a deploy host in PROJECT.md, refusing" >&2; exit 1 ;;
esac
[ "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" = "$(cd "$CANONICAL_PATH" 2>/dev/null && pwd -P)" ] \
  || { echo "deploy: run this from $CANONICAL_PATH, the live checkout on $HOST; refusing" >&2; exit 1; }
cd "$CANONICAL_PATH"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "deploy: not on main, refusing" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "deploy: dirty tree, refusing" >&2; exit 1; }
# The revision to deploy: DEPLOY_REV, or origin/main.
live_rev() { git rev-parse -q --verify "${DEPLOY_REV:-origin/main}^{commit}"; }
if [ -n "${DEPLOY_UPDATED:-}" ]; then
  # Rerun below by the version that was here before the move. One whose deploy.sh predates this file
  # set no DEPLOY_FROM, so take the commit before its merge from the reflog.
  unset DEPLOY_UPDATED
  [ "$(git rev-parse HEAD)" = "$(live_rev)" ] || { echo "deploy: not at the revision to deploy after moving to it, refusing" >&2; exit 1; }
  DEPLOY_FROM=${DEPLOY_FROM:-$(git rev-parse -q --verify 'HEAD@{1}' || git rev-parse HEAD)}
else
  git fetch --quiet origin main
  DEPLOY_FROM=$(git rev-parse HEAD)
  live_to=$(live_rev) && git merge-base --is-ancestor "$live_to" origin/main \
    || { echo "deploy: DEPLOY_REV=${DEPLOY_REV:-} is not a commit on origin/main, refusing; deploy only merged revisions" >&2; exit 1; }
  if [ "$DEPLOY_FROM" = "$live_to" ]; then
    # Nothing new: deploy only when asked to (any argument) or when deploy.sh has work pending.
    [ $# -gt 0 ] || { declare -F deploy_pending >/dev/null && deploy_pending; } || exit 0
  else
    git merge-base --is-ancestor HEAD origin/main \
      || { echo "deploy: local commits not on origin/main, refusing; push them to a branch and open a PR" >&2; exit 1; }
    # The version that arrives reruns this, so it must know DEPLOY_REV too.
    [ -z "${DEPLOY_REV:-}" ] || git show "$live_to:scripts/live.sh" 2>/dev/null | grep -q DEPLOY_REV \
      || { echo "deploy: ${live_to:0:7} predates DEPLOY_REV in scripts/live.sh, so it cannot be redeployed this way; refusing" >&2; exit 1; }
    # Never replace an ignored file, such as .env, with one that the revision tracks.
    git checkout --quiet --no-overwrite-ignore -B main "$live_to" \
      || { echo "deploy: could not move to ${live_to:0:7} without overwriting the files above, refusing" >&2; exit 1; }
    # Run the rest from the version of deploy.sh (and of this file) that just arrived, with the same arguments.
    DEPLOY_UPDATED=1 DEPLOY_FROM="$DEPLOY_FROM" exec "$CANONICAL_PATH/scripts/deploy.sh" "$@"
  fi
fi
export DEPLOY_FROM
# The deploy record (see above), written when deploy.sh ends: ok only once its smoke test has passed.
live_record=$(cd "$(git rev-parse --git-path deploys | sed 's|/deploys$||')" && pwd -P)/deploys
live_end() {
  local rc=$1 at head good
  at=$(date -u +%FT%TZ) head=$(git -C "$CANONICAL_PATH" rev-parse HEAD)
  if [ "$rc" -eq 0 ]; then
    echo "$at $head ok" >>"$live_record"
    echo "deploy: $at $(git -C "$CANONICAL_PATH" rev-parse --short HEAD) on $HOST"
    if declare -F deploy_pending >/dev/null && deploy_pending; then
      echo "deploy: part of this deploy is still pending; a later scripts/deploy.sh finishes it"
    fi
  else
    good=$(awk '$3 == "ok" { c = $2 } END { print c }' "$live_record" 2>/dev/null)
    echo "$at $head failed" >>"$live_record"
    echo "deploy: FAILED at ${head:0:7} on $HOST. Retry: scripts/deploy.sh --force$([ -z "$good" ] || [ "$good" = "$head" ] || echo ". Restore the last good release: DEPLOY_REV=$good scripts/deploy.sh")" >&2
  fi
}
trap 'live_rc=$?; live_end "$live_rc" || :; exit $live_rc' EXIT
