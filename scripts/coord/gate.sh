#!/bin/bash
# Serializes commands that run BotChu's rendering tests (global AppKit window focus) across the agents
# on this Mac, one at a time:
#   gate.sh start <command…>     queues <command>, run from the current directory, behind the lock,
#                                detached; prints a run id
#   gate.sh wait <id> [seconds]  waits up to <seconds> (default 110, at most 540) and prints the state;
#                                when done, the exit code, the failures and the log's tail (exit = its exit)
#   gate.sh status               the lock's holder and the runs queued
# A run is killed after 45 minutes. Before a run starts, it also waits for test processes started outside
# the gate (busy.sh) to end.
set -u
D=${BOTCHU_COORD_ROOT:-/tmp/botchu-coord}/gate
mkdir -p "$D/runs"
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

case "${1:-}" in
start)
  shift
  [ $# -gt 0 ] || { echo "usage: gate.sh start <command…>" >&2; exit 2; }
  id=$(date +%H%M%S)-$$
  run="$D/runs/$id"
  mkdir -p "$run"
  pwd -P > "$run/cwd"
  printf '%q ' "$@" > "$run/cmd"
  date +%s > "$run/queued-at"
  echo queued > "$run/state"
  nohup "$self" _run "$id" > "$run/runner.log" 2>&1 < /dev/null &
  echo "$id"
  ;;
_run)
  id=$2
  run="$D/runs/$id"
  while :; do
    if mkdir "$D/lock" 2> /dev/null; then
      echo $$ > "$D/lock/pid"
      echo "$id" > "$D/lock/run"
      break
    fi
    holder=$(cat "$D/lock/pid" 2> /dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2> /dev/null; then
      rm -rf "$D/lock"
      continue
    fi
    sleep 5
  done
  trap 'rm -rf "$D/lock"' EXIT
  echo "waiting for tests started outside the gate" > "$run/state"
  while [ -n "$("$(dirname "$self")/busy.sh")" ]; do sleep 10; done
  echo running > "$run/state"
  date > "$run/started"
  date +%s > "$run/started-at"
  set -m
  (export BOTCHU_GATE_RUN_ID="$id"; cd "$(cat "$run/cwd")" && eval "$(cat "$run/cmd")") > "$run/log" 2>&1 &
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2> /dev/null; do
    if [ $((SECONDS - start)) -gt 2700 ]; then
      echo "gate: killed after 45 minutes" >> "$run/log"
      kill -TERM -- "-$pid" 2> /dev/null
      sleep 10
      kill -KILL -- "-$pid" 2> /dev/null
      break
    fi
    sleep 3
  done
  wait "$pid"
  echo $? > "$run/exit"
  date +%s > "$run/finished-at"
  echo done > "$run/state"
  ;;
wait)
  id=${2:?usage: gate.sh wait <id> [seconds]}
  limit=${3:-110}
  [ "$limit" -gt 540 ] && limit=540
  run="$D/runs/$id"
  [ -d "$run" ] || { echo "gate: no run $id" >&2; exit 2; }
  end=$((SECONDS + limit))
  while [ "$(cat "$run/state")" != done ] && [ $SECONDS -lt $end ]; do sleep 3; done
  state=$(cat "$run/state")
  if [ "$state" = done ]; then
    code=$(cat "$run/exit")
    echo "gate: run $id done, exit $code; full log: $run/log"
    echo "--- failures"
    grep -E "✘|􀢄|error:|: failed|FAIL|issue recorded|Fatal" "$run/log" | grep -v "^warning" | head -40
    echo "--- tail"
    tail -25 "$run/log"
    exit "$code"
  fi
  echo "gate: run $id is $state (the lock is held by run $(cat "$D/lock/run" 2> /dev/null || echo none)); call wait again"
  [ -f "$run/log" ] && tail -3 "$run/log"
  exit 75
  ;;
status)
  echo "lock: $(cat "$D/lock/run" 2> /dev/null || echo free)"
  for r in "$D"/runs/*; do
    [ -d "$r" ] || continue
    s=$(cat "$r/state")
    [ "$s" = done ] && continue
    echo "$(basename "$r"): $s in $(cat "$r/cwd"): $(cat "$r/cmd")"
  done
  ;;
*)
  sed -n '2,10p' "$self"
  exit 2
  ;;
esac
