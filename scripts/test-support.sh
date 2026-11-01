#!/usr/bin/env bash
# Shared timing and SwiftPM reporting for the two test entry points.
test_begin() {
  test_started=$SECONDS
  if [ -z "${BOTCHU_TEST_RESULTS:-}" ]; then
    BOTCHU_TEST_RESULTS="$test_root/macOS/.build/test-results/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    export BOTCHU_TEST_RESULTS
    BOTCHU_TEST_REPORT_OWNER=$$
    export BOTCHU_TEST_REPORT_OWNER
  fi
  mkdir -p "$BOTCHU_TEST_RESULTS"
  echo "test: $1 start; load $(sysctl -n vm.loadavg); results $BOTCHU_TEST_RESULTS"
}

test_end() {
  local result=$1
  echo "test: finished in $((SECONDS - test_started))s, exit $result; load $(sysctl -n vm.loadavg)"
  if [ "${BOTCHU_TEST_REPORT_OWNER:-}" = "$$" ]; then
    python3 "$test_root/scripts/test-report.py" "$BOTCHU_TEST_RESULTS"
  fi
}

test_step() {
  local label=$1 began=$SECONDS result
  shift
  echo "test: $label start; load $(sysctl -n vm.loadavg)"
  if "$@"; then result=0; else result=$?; fi
  echo "test: $label took $((SECONDS - began))s, exit $result; load $(sysctl -n vm.loadavg)"
  # Deploy keeps the steps' times for the release it records (scripts/release-record.py).
  [ -z "${BOTCHU_TEST_STEPS:-}" ] || printf '%s\t%s\n' "$label" "$((SECONDS - began))" >> "$BOTCHU_TEST_STEPS"
  return "$result"
}

test_run() {
  local label=$1 result output xml
  shift
  output="$BOTCHU_TEST_RESULTS/$label.log"
  xml="$BOTCHU_TEST_RESULTS/$label.xml"
  python3 "$test_root/scripts/test-report.py" --command "$xml" swift test --package-path "$test_root/macOS" "$@"
  swift test --package-path "$test_root/macOS" --xunit-output "$xml" "$@" 2>&1 |
    tee "$output" | { grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]| started\.$' || true; }
  result=${PIPESTATUS[0]}
  # Some SwiftPM versions return success when a bundle fails or exits early.
  if grep -Eq 'Some test targets reported failures:|Test run with .* failed after|Test .* failed after .* issue' "$output"; then result=1; fi
  if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed after' "$output"; then
    echo "test: $label did not finish successfully" >&2
    result=1
  fi
  if [ "$result" != 0 ]; then python3 "$test_root/scripts/test-report.py" --failed "$xml"; fi
  return "$result"
}

# A pre-upgrade /tmp gate does not export the marker yet. Recognize its real ancestor too,
# so the formerly documented outer-gate command cannot deadlock on the first upgraded run.
test_inside_gate() {
  [ -n "${BOTCHU_GATE_RUN_ID:-}" ] || python3 "$test_root/scripts/coord/busy.py" --in-gate
}
