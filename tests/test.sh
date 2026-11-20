#!/bin/bash
# End-to-end tests for progress-helper. Windows appear on screen briefly while it runs.
# Usage: tests/test.sh [path/to/progress-helper]

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PH="${1:-$ROOT/build/progress-helper}"
[ -x "$PH" ] || { echo "not executable: $PH" >&2; exit 2; }

pass=0; fail=0; sessions=()
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$3', got '$2')"; }
checknum() { awk -v a="$2" -v b="$3" 'BEGIN{exit !(a+0 == b+0)}' && ok "$1" || bad "$1 (expected $3, got '$2')"; }
section() { echo; echo "$1"; }

pidof_session() { cat "$1/pid" 2>/dev/null; }
alive() { local p; p=$(pidof_session "$1"); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
wait_dead() { for _ in $(seq 1 ${2:-60}); do alive "$1" || return 0; sleep 0.05; done; return 1; }
raw() { alive "$1" && printf '%s\n' "$2" > "$1/cmd"; }
state() {
    rm -f "$1/state.json"; raw "$1" "__dump" || return 1
    for _ in $(seq 1 60); do [ -f "$1/state.json" ] && break; sleep 0.05; done
    plutil -extract "$2" raw -o - "$1/state.json" 2>/dev/null
}
start() { local id; id=$("$PH" start "$@") || return 1; sessions+=("$id"); sleep 0.3; echo "$id"; }
cleanup() { for s in "${sessions[@]:-}"; do [ -d "$s" ] && "$PH" end "$s" >/dev/null 2>&1; done; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "Command line"
"$PH" >/dev/null 2>&1;                      check "no arguments exits 64" "$?" 64
"$PH" frobnicate >/dev/null 2>&1;           check "unknown command exits 64" "$?" 64
"$PH" update /nonexistent >/dev/null 2>&1;  check "unknown session exits 66" "$?" 66
"$PH" start --total abc >/dev/null 2>&1;    check "non-numeric --total exits 64" "$?" 64

# ---------------------------------------------------------------------------
section "Starting a session"
id=$(start --label "Copying files" --status "Getting ready")
[ -d "$id" ] && ok "start prints a session folder" || bad "start prints a session folder ($id)"
[ -p "$id/cmd" ] && ok "session has a named pipe" || bad "session has a named pipe"
alive "$id" && ok "window process is running" || bad "window process is running"
p=$(pidof_session "$id"); pg=$(ps -o pgid= -p "$p" | tr -d ' ')
check "window runs in its own process group" "$pg" "$p"
check "window is visible" "$(state "$id" visible)" true
check "label shows" "$(state "$id" label)" "Copying files"
check "status shows" "$(state "$id" status)" "Getting ready"
check "bar starts in waiting mode" "$(state "$id" indeterminate)" true
checknum "window width matches Finder (404)" "$(state "$id" width)" 404
checknum "window height matches Finder (88)" "$(state "$id" height)" 88
check "window opens on the primary display" "$(state "$id" screenIndex)" 0
"$PH" cancelled "$id"; check "cancelled exits 1 when not stopped" "$?" 1

# ---------------------------------------------------------------------------
section "Updates"
"$PH" update "$id" --label "Exporting “Report.pdf”" --status "About a minute"
check "label updates" "$(state "$id" label)" "Exporting “Report.pdf”"
check "status updates" "$(state "$id" status)" "About a minute"
"$PH" update "$id" --total 50 --completed 20
check "total switches to a real bar" "$(state "$id" indeterminate)" false
checknum "bar value" "$(state "$id" value)" 20
checknum "bar maximum" "$(state "$id" max)" 50
"$PH" update "$id" --indeterminate
check "--indeterminate switches back to waiting" "$(state "$id" indeterminate)" true
"$PH" update "$id" --completed 10
check "--completed alone leaves waiting mode" "$(state "$id" indeterminate)" false
checknum "keeps the earlier maximum" "$(state "$id" max)" 50
"$PH" update "$id" --completed 999
checknum "value is capped at the maximum" "$(state "$id" value)" 50
"$PH" update "$id" --status ""
check "empty status clears the line" "$(state "$id" status)" ""

# ---------------------------------------------------------------------------
section "Icons and layout"
work=$(mktemp -d); touch "$work/Quarterly Report.pdf" "$work/clip.mp4"; mkdir "$work/Photos"
layout_is() {  # session name expect-icon expect-left expect-bar-width expect-text-width
    check "$2: icon shown = $3" "$(state "$1" hasIcon)" "$3"
    check "$2: icon view hidden = $([ "$3" = true ] && echo false || echo true)" "$(state "$1" iconHidden)" "$([ "$3" = true ] && echo false || echo true)"
    checknum "$2: label starts at $4" "$(state "$1" labelX)" "$4"
    checknum "$2: bar starts at $4" "$(state "$1" barX)" "$4"
    checknum "$2: status starts at $4" "$(state "$1" statusX)" "$4"
    checknum "$2: bar width $5" "$(state "$1" barWidth)" "$5"
    checknum "$2: label width $6" "$(state "$1" labelWidth)" "$6"
}
n=$(start --label "Copying files")
layout_is "$n" "no icon" false 20 350.5 372
"$PH" end "$n"
n=$(start --label "Exporting “Quarterly Report.pdf”" --icon "$work/Quarterly Report.pdf")
layout_is "$n" "document icon at start" true 62 308.5 330
"$PH" end "$n"
"$PH" update "$id" --icon "$work/clip.mp4"
layout_is "$id" "video icon by update" true 62 308.5 330
"$PH" update "$id" --icon "$work/Photos"
check "folder icon" "$(state "$id" hasIcon)" true
"$PH" update "$id" --icon /System/Applications/TextEdit.app
check "app icon" "$(state "$id" hasIcon)" true
"$PH" update "$id" --icon "$work/does-not-exist.txt"
check "missing file still gets a generic icon" "$(state "$id" hasIcon)" true
"$PH" update "$id" --no-icon
layout_is "$id" "--no-icon clears it" false 20 350.5 372
"$PH" update "$id" --icon "$work/clip.mp4"
layout_is "$id" "icon added back" true 62 308.5 330
"$PH" update "$id" --no-icon
rm -rf "$work"

# ---------------------------------------------------------------------------
section "Text is shown literally"
tricky="It's \"quoted\" \$HOME \`date\` ; rm -rf ~ ✅ café 日本"
"$PH" update "$id" --label "$tricky"
check "quotes, \$, backticks, emoji and accents" "$(state "$id" label)" "$tricky"
"$PH" update "$id" --status "$(printf 'line one\nline two')"
check "line breaks collapse to spaces" "$(state "$id" status)" "line one line two"

# ---------------------------------------------------------------------------
section "Rapid updates"
"$PH" update "$id" --total 300
errs=0; for i in $(seq 1 300); do "$PH" update "$id" --completed "$i" || errs=$((errs + 1)); done
check "300 updates in a row, none rejected" "$errs" 0
checknum "final value is exact" "$(state "$id" value)" 300

# ---------------------------------------------------------------------------
section "Ending a session"
p=$(pidof_session "$id"); t0=$(date +%s)
"$PH" end "$id"; check "end exits 0" "$?" 0
kill -0 "$p" 2>/dev/null && bad "window process is gone" || ok "window process is gone"
[ -d "$id" ] && bad "session folder is removed" || ok "session folder is removed"
[ $(( $(date +%s) - t0 )) -le 1 ] && ok "end finishes within a second" || bad "end finishes within a second"

# ---------------------------------------------------------------------------
section "Stopping (stop button and close button share this path)"
id=$(start --label "Copying files" --total 10 --completed 3)
raw "$id" "__stop"
wait_dead "$id" && ok "window closes at once" || bad "window closes at once"
"$PH" cancelled "$id"; check "cancelled exits 0" "$?" 0
sleep 3
"$PH" cancelled "$id"; check "still reports cancelled 3 seconds later" "$?" 0
"$PH" update "$id" --completed 5; check "update after stop exits 0 quietly" "$?" 0
"$PH" end "$id"; check "end after stop exits 0" "$?" 0
[ -d "$id" ] && bad "end removes the stopped session" || ok "end removes the stopped session"

# ---------------------------------------------------------------------------
section "Red close button"
id=$(start --label "Copying files" --total 10 --completed 3)
p=$(pidof_session "$id")
raw "$id" "__close"
wait_dead "$id" 20 && ok "close button: process exits within a second" || bad "close button: process exits within a second"
"$PH" cancelled "$id"; check "close button counts as a stop" "$?" 0
"$PH" end "$id"

# ---------------------------------------------------------------------------
section "Window crashes"
id=$(start --label "Copying files")
kill -9 "$(pidof_session "$id")"; sleep 0.3
"$PH" update "$id" --completed 1; check "update reports a lost window (69)" "$?" 69
"$PH" cancelled "$id"; check "a crash is not a stop" "$?" 1
"$PH" end "$id"; check "end cleans up after a crash" "$?" 0
[ -d "$id" ] && bad "crashed session folder removed" || ok "crashed session folder removed"

# ---------------------------------------------------------------------------
section "Calling script dies"
sleep 60 & owner=$!
id=$(start --label "Copying files" --watch-pid "$owner")
alive "$id" && ok "window stays up while the script runs" || bad "window stays up while the script runs"
kill "$owner"; wait "$owner" 2>/dev/null
wait_dead "$id" 60 && ok "window closes within 3 seconds of the script dying" || bad "window closes within 3 seconds of the script dying"
"$PH" cancelled "$id"; check "script death is not a stop" "$?" 1
"$PH" end "$id"

# ---------------------------------------------------------------------------
section "Two sessions at once"
a=$(start --label "Copying A")
b=$(start --label "Copying B")
"$PH" update "$a" --total 10 --completed 2
"$PH" update "$b" --total 10 --completed 7
check "A keeps its own label" "$(state "$a" label)" "Copying A"
check "B keeps its own label" "$(state "$b" label)" "Copying B"
checknum "A keeps its own value" "$(state "$a" value)" 2
checknum "B keeps its own value" "$(state "$b" value)" 7
ax=$(state "$a" x); bx=$(state "$b" x)
awk -v a="$ax" -v b="$bx" 'BEGIN{exit !(b > a)}' && ok "B opens offset from A" || bad "B opens offset from A (A x=$ax, B x=$bx)"
check "B also opens on the primary display" "$(state "$b" screenIndex)" 0
raw "$a" "__stop"; wait_dead "$a"
alive "$b" && ok "stopping A leaves B running" || bad "stopping A leaves B running"
"$PH" cancelled "$b"; check "B is not cancelled" "$?" 1
"$PH" end "$a"; "$PH" end "$b"

# ---------------------------------------------------------------------------
section "Launch contexts"
id=$(env -i HOME="$HOME" PATH=/usr/bin:/bin "$PH" start --label "Minimal environment"); sessions+=("$id"); sleep 0.3
check "works with a stripped environment, like a Quick Action" "$(state "$id" visible)" true
"$PH" end "$id"

id=$(osascript -e "do shell script quoted form of \"$PH\" & \" start --label \" & quoted form of \"From AppleScript\"")
sessions+=("$id"); sleep 1.5
alive "$id" && ok "AppleScript do shell script: window survives the call returning" || bad "AppleScript do shell script: window survives the call returning"
check "AppleScript-launched window is visible" "$(state "$id" visible)" true
"$PH" end "$id"

# ---------------------------------------------------------------------------
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
