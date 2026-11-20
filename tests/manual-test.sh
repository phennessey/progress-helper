#!/bin/bash
# Hands-on checks that need a person: clicking the stop button and close button,
# the pressed state, and how windows look. Each window explains what to do.
# Usage: tests/manual-test.sh [file-to-use-as-icon]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PH="${PH:-$ROOT/build/progress-helper}"
ICON="${1:-/System/Applications/TextEdit.app}"
NAME="$(basename "$ICON")"

wait_for_stop() {  # session seconds -> prints how long until stopped, or "timed out"
    local id="$1" limit="$2" t=0 total=60
    "$PH" update "$id" --total "$total" --completed 0
    while [ $t -lt $((limit * 10)) ]; do
        if "$PH" cancelled "$id"; then echo "stopped after $((t / 10)).$((t % 10))s"; return 0; fi
        local done=$(( (t / 10) % total ))
        "$PH" update "$id" --completed "$done" --status "About $((total - done)) seconds"
        sleep 0.1; t=$((t + 1))
    done
    echo "timed out"; return 1
}

run_round() {  # label-for-waiting label-for-progress
    local id
    id=$("$PH" start --icon "$ICON" --label "Preparing “$NAME”" --indeterminate --watch-pid $$)
    sleep 3
    "$PH" update "$id" --label "$1"
    local result; result=$(wait_for_stop "$id" 120)
    local window_gone=no pid; pid=$(cat "$id/pid" 2>/dev/null)
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || { window_gone=yes; break; }; sleep 0.1; done
    "$PH" end "$id"
    echo "$result, window closed: $window_gone"
}

echo "1. stop button:  $(run_round "Test 1: click the ✕ beside the bar")"
echo "2. close button: $(run_round "Test 2: click the red close button")"

a=$("$PH" start --icon "$ICON" --label "Test 3: two windows, first" --total 10 --completed 3 --status "Closes by itself")
b=$("$PH" start --icon "$ICON" --label "Test 3: two windows, second" --total 10 --completed 7 --status "Closes by itself")
sleep 6; "$PH" end "$a"; "$PH" end "$b"
echo "3. two windows:  shown for 6 seconds"

c=$("$PH" start --label "Test 4: no icon, full-width layout" --total 10 --completed 5 --status "Closes by itself")
sleep 6; "$PH" end "$c"
echo "4. no icon:      shown for 6 seconds"
