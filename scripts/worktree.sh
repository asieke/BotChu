#!/usr/bin/env bash
# One Git worktree per task, so the main checkout stays on main and agents never share files:
#   scripts/worktree.sh <type>/<slug>   creates .claude/worktrees/<type>-<slug> in the main checkout on a
#                                       new branch from origin/main (or reopens the task's branch), links
#                                       .env, and prints the path, so agents start a task with:
#                                       dir=$(scripts/worktree.sh feat/12-add-login) && cd "$dir"
#                                       A new <type>/<number>-<slug> branch is made on GitHub, linked to
#                                       Issue #number (gh issue develop), which shows it under Development.
#   scripts/worktree.sh --env           links the main checkout's .env files into worktrees that lack them
#   scripts/worktree.sh --tidy          removes worktrees whose pull request merged, with their branches,
#                                       and lists the rest
# Never forces: a worktree with uncommitted or untracked files, or a commit no merged PR contains, stays.
# Identical in every project: copy it from asieke/workspace templates/common/scripts/worktree.sh.
set -euo pipefail
start=$(pwd -P)
cd "$(dirname "$0")/.."
main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
cd "$main"

# Linked worktrees (the main checkout is listed first and skipped), one per line:
# path <TAB> branch, or - when detached <TAB> ok | detached | locked | prunable <TAB> lock reason
worktrees() {
  git worktree list --porcelain | awk '
    function flush() { if (n > 1) printf "%s\t%s\t%s\t%s\n", p, b, s, r }
    /^worktree / { flush(); n++; p = substr($0, 10); b = "-"; s = "ok"; r = "" }
    /^branch refs\/heads\// { b = substr($0, 19) }
    /^detached$/ { s = "detached" }
    /^locked/ { s = "locked"; r = substr($0, 8) }
    /^prunable/ { s = "prunable" }
    END { flush() }'
}

# link_env DIR: symlink each .env file at the main checkout's root into DIR, unless DIR already has one
# or Git would not ignore it there. A link keeps one copy of each secret on the machine.
link_env() {
  local f name
  for f in "$main"/.env "$main"/.env.*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    [ -e "$1/$name" ] || [ -L "$1/$name" ] && continue
    if git -C "$1" check-ignore -q --no-index "$name"; then
      ln -s "$f" "$1/$name" && echo "worktree: linked $name into $1" >&2
    else
      echo "worktree: not linking $name into $1, because Git does not ignore it there" >&2
    fi
  done
}

# keep DIR BRANCH REASON: report a worktree that stays, with the days since Git last wrote to it.
keep() {
  local gd t idle=
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) &&
    t=$(stat -c %Y "$gd" 2>/dev/null || stat -f %m "$gd" 2>/dev/null) && idle=", idle $(( ($(date +%s) - t) / 86400 ))d"
  echo "worktree: kept $1 ($2: $3$idle)"
}

# merged BRANCH: true if GitHub deleted the pushed branch and its last commit is on origin/main or is the
# head of a merged pull request (squash merges leave no other trace). Otherwise sets why.
merged() {
  local tip oid
  tip=$(git rev-parse "refs/heads/$1")
  if [ -z "$(git for-each-ref --format='%(upstream)' "refs/heads/$1")" ]; then
    why="not pushed yet"; return 1
  fi
  if [ "$(git for-each-ref --format='%(upstream:track)' "refs/heads/$1")" != "[gone]" ]; then
    why="pull request open, or branch not deleted on GitHub yet"; return 1
  fi
  git merge-base --is-ancestor "$tip" origin/main 2>/dev/null && return 0
  if command -v gh >/dev/null; then
    for oid in $(GH_PROMPT_DISABLED=1 gh pr list --head "$1" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null); do
      [ "$oid" = "$tip" ] && return 0
      git cat-file -e "$oid^{commit}" 2>/dev/null && git merge-base --is-ancestor "$tip" "$oid" && return 0
    done
  fi
  why="branch deleted on GitHub, but no merged pull request has its last commit"; return 1
}

# alive LOCK_REASON: false only if the lock names a process that has exited. Claude Code locks its
# worktrees as "claude session <name> (pid <pid> start <date>)", and a `claude -p` run never unlocks.
alive() {
  local pid
  pid=$(printf '%s\n' "$1" | sed -n 's/.*(pid \([0-9][0-9]*\).*/\1/p')
  [ -z "$pid" ] || ps -p "$pid" >/dev/null 2>&1
}

# owners DIR: the branches a tool detached the task worktree DIR from, that is, branches that point at
# its last commit and are not checked out anywhere. Only for worktrees in .claude/worktrees/, since
# scripts/verify-pr.sh runs checks in detached worktrees elsewhere.
owners() {
  case "$1" in "$main/.claude/worktrees/"*) ;; *) return 0;; esac
  git for-each-ref --points-at "$(git -C "$1" rev-parse HEAD)" refs/heads/ \
    --format='%(if)%(worktreepath)%(then)%(else)%(refname:short)%(end)'
}

tidy() {
  local here wt br st lock why reason b
  git fetch --quiet --prune origin || echo "worktree: could not fetch origin, so merged work may be missed" >&2
  # Never remove the worktree the caller is standing in.
  here=$(cd "$start" && cd "$(git rev-parse --show-toplevel 2>/dev/null)" && pwd -P) || here=
  while IFS=$'\t' read -r wt br st lock <&3; do
    case "$st" in
      prunable) echo "worktree: pruned $wt (folder no longer exists)"; continue;;
      locked)   if alive "$lock"; then keep "$wt" "$br" "locked${lock:+: $lock}"; continue; fi;;
    esac
    if [ "$(cd "$wt" && pwd -P)" = "$here" ]; then keep "$wt" "$br" "current directory"; continue; fi
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then keep "$wt" "$br" "uncommitted or untracked files"; continue; fi
    if [ "$br" = - ]; then
      reason="detached HEAD"
      for b in $(owners "$wt"); do
        if merged "$b"; then br=$b; break; fi
        reason="$reason; $b: $why"
      done
      [ "$br" != - ] || { keep "$wt" - "$reason"; continue; }
    elif ! merged "$br"; then
      keep "$wt" "$br" "$why"; continue
    fi
    { [ "$st" != locked ] || git worktree unlock "$wt"; } &&
      git worktree remove "$wt" && git branch -D --quiet "$br" && echo "worktree: removed $wt and branch $br (merged)"
  done 3< <(worktrees)
  git worktree prune
}

# linked BRANCH: for a new <type>/<number>-<slug> branch, have GitHub create it from main, linked to
# Issue #number (gh issue develop), so the Issue shows who is on it under Development; then fetch it.
# False without gh, or when GitHub refuses (no such Issue, say): the branch is then made here instead.
linked() {
  local n
  [[ "$1" =~ ^[a-z]+/([0-9]+)- ]] && command -v gh >/dev/null || return 1
  n=${BASH_REMATCH[1]}
  GH_PROMPT_DISABLED=1 gh issue develop "$n" --name "$1" --base main >/dev/null 2>&1 \
    && git fetch --quiet origin "+refs/heads/$1:refs/remotes/origin/$1" 2>/dev/null || return 1
  echo "worktree: created $1 on GitHub, linked to Issue #$n" >&2
}

create() {
  local branch=$1 dir
  [[ "$branch" =~ ^(feat|fix|chore|docs)/[a-z0-9-]+$ ]] && [ ${#branch} -le 50 ] || {
    echo "worktree: '$branch' is not <feat|fix|chore|docs>/<slug> in lowercase letters, numbers, and hyphens (at most 50 characters)" >&2
    exit 2
  }
  # Reopen the branch's worktree wherever it is, such as one that `claude --worktree` created and the agent renamed.
  dir=$(worktrees | awk -F'\t' -v b="$branch" '$2 == b && $3 != "prunable" { d = $1 } END { print d }')
  [ -n "$dir" ] || dir="$main/.claude/worktrees/${branch/\//-}"
  if [ -e "$dir" ]; then
    [ "$(git -C "$dir" symbolic-ref --short -q HEAD)" = "$branch" ] || { echo "worktree: $dir exists but is not on $branch" >&2; exit 1; }
    echo "worktree: reopened $dir" >&2
  else
    git check-ignore -q --no-index .claude/worktrees/x || {
      echo "worktree: .gitignore must ignore .claude/worktrees/ first, or the main checkout looks dirty" >&2; exit 1; }
    git fetch --quiet origin main
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add --quiet "$dir" "$branch"
    elif git fetch --quiet origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || linked "$branch"; then
      git worktree add --quiet --track -b "$branch" "$dir" "origin/$branch"
    else
      git worktree add --quiet --no-track -b "$branch" "$dir" origin/main
    fi
    echo "worktree: created $dir on $branch" >&2
  fi
  link_env "$dir"
  echo "$dir"
}

case "${1:-}" in
  --env)
    while IFS=$'\t' read -r wt _ st _ <&3; do
      [ "$st" = prunable ] || link_env "$wt"
    done 3< <(worktrees);;
  --tidy) tidy;;
  ""|-*) sed -n '2,11p' "$0" >&2; exit 2;;
  *) create "$1";;
esac
