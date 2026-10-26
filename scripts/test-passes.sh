#!/usr/bin/env bash
# A receipt certifies a clean Git tree, not its commit's parentage or branch name.
test_capture_tree() {
  test_initial_tree=
  if [ -z "$(git status --porcelain)" ]; then test_initial_tree=$(git rev-parse 'HEAD^{tree}'); fi
}

test_tree_passed() {
  local tree receipts
  tree=$(git rev-parse 'HEAD^{tree}')
  receipts="$(git rev-parse --git-common-dir)/test-passes"
  [ -f "$receipts" ] && awk -v tree="$tree" '$1 == tree { found=1 } END { exit !found }' "$receipts"
}

test_record_pass() {
  local tree receipts
  tree=$(git rev-parse 'HEAD^{tree}')
  if [ -z "${test_initial_tree:-}" ] || [ "$tree" != "$test_initial_tree" ] || [ -n "$(git status --porcelain)" ]; then
    echo "test: no pass receipt: the tree was dirty or changed during the run"
    return
  fi
  receipts="$(git rev-parse --git-common-dir)/test-passes"
  printf '%s %s %s\n' "$tree" "$(git rev-parse HEAD)" "$(date -u +%FT%TZ)" >> "$receipts"
  echo "test: recorded full pass for tree $tree"
}
