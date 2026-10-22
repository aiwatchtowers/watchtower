#!/bin/bash
# Tests for scripts/swift-test-sharded.sh's end-of-run failure summary
# (summarize_failure + print_summary), extracted verbatim from the script and
# run on fixture lane logs — no build, no xctest.
#
# Covers:
#   - an XCTest assertion                      → the assertion and failed lines,
#     the last started test
#   - SIGSEGV (exit 139) after an assertion    → the assertion AND the signal AND
#     the last started test
#   - a lane the watchdog killed               → "hung past …s, killed by the
#     watchdog", not a bare signal
#   - a startup exit with no test started      → the lane's last 10 lines
#   - a Swift Testing ✘ failure                → the ✘ lines
#   - a Swift Testing crash                    → the last "◇ Test … started"
#   - Swift Testing dies after its run banner  → "no test started" and the
#     log tail, not the banner as a test
#   - CoreData's "error:" log noise            → not reported as a failure
#   - print_summary: nothing failed → no output; a crash report of xctest or
#     swiftpm-testing-helper written during the run is printed, an older one
#     and another process's are not
# shellcheck disable=SC2034  # LANE_TIMEOUT, signalled, names: read by the eval'd functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../swift-test-sharded.sh"

FAILURES=0

note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

# check <label> <haystack> <needle>
check() {
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *)
            note_fail "$1 — missing: $3"
            printf '%s\n' "$2" | sed 's/^/    | /'
            ;;
    esac
}

# check_absent <label> <haystack> <needle>
check_absent() {
    case "$2" in
        *"$3"*)
            note_fail "$1 — unexpected: $3"
            printf '%s\n' "$2" | sed 's/^/    | /'
            ;;
        *) echo "ok: $1" ;;
    esac
}

FUNCS="$(sed -n '/^summarize_failure() {/,/^}/p;/^print_summary() {/,/^}/p' "$SCRIPT")"
case "$FUNCS" in
    *"summarize_failure() {"*"print_summary() {"*) ;;
    *)
        echo "FAIL: could not extract the summary functions from $SCRIPT"
        exit 1
        ;;
esac
eval "$FUNCS"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOME="$WORK/home"
mkdir -p "$HOME/Library/Logs/DiagnosticReports"
# The script's globals the extracted functions read.
LANE_TIMEOUT=600
signalled=0
names=()

# lane <index> <name> <log text>
lane() {
    names[$1]="$2"
    printf '%s\n' "$3" > "$WORK/log$1"
}

# --- an XCTest assertion
lane 0 "XCTest shard 1/3" "Test Suite 'B' started at now.
CoreData: error: Failed to create NSXPCConnection
Test Case '-[A.B testX]' started.
/x/B.swift:9: error: -[A.B testX] : XCTAssertTrue failed
Test Case '-[A.B testX]' failed (0.1 seconds)."
out="$(summarize_failure 0 1)"
check "assertion: header" "$out" "XCTest shard 1/3 (exit 1):"
check "assertion: error line" "$out" "  /x/B.swift:9: error: -[A.B testX] : XCTAssertTrue failed"
check "assertion: failed line" "$out" "  Test Case '-[A.B testX]' failed (0.1 seconds)."
check "assertion: last started" "$out" "  last started: Test Case '-[A.B testX]' started."
check_absent "assertion: no signal" "$out" "signal"
check_absent "assertion: CoreData noise" "$out" "CoreData"

# --- SIGSEGV after an assertion
lane 1 "XCTest shard 2/3" "Test Case '-[A.B testX]' started.
/x/B.swift:9: error: -[A.B testX] : XCTAssertEqual failed
Test Case '-[A.B testX]' failed (0.1 seconds).
Test Case '-[A.C testY]' started."
out="$(summarize_failure 1 139)"
check "segv: assertion" "$out" "error: -[A.B testX] : XCTAssertEqual failed"
check "segv: signal" "$out" "  killed by signal 11"
check "segv: last started" "$out" "  last started: Test Case '-[A.C testY]' started."

# --- the watchdog killed a hung lane
lane 2 "XCTest shard 3/3" "Test Case '-[A.D testHangs]' started."
: > "$WORK/killed2"
out="$(summarize_failure 2 143)"
check "watchdog: says so" "$out" "  hung past 600s, killed by the watchdog"
check_absent "watchdog: no bare signal" "$out" "killed by signal"
check "watchdog: last started" "$out" "  last started: Test Case '-[A.D testHangs]' started."

# --- a startup exit with no test started
log="dyld: Library not loaded"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do log="$log
line $n"; done
lane 3 "XCTest shard 1/3" "$log"
out="$(summarize_failure 3 1)"
check "startup: says no test started" "$out" "  no test started; the lane's last lines:"
check "startup: last line" "$out" "    line 12"
check "startup: tenth from the end" "$out" "    line 3"
check_absent "startup: older lines left out" "$out" "Library not loaded"

# --- a Swift Testing failure
lane 4 "Swift Testing" "◇ Test run started.
◇ Suite \"Parser\" started.
◇ Test parsesEmpty() started.
✘ Test parsesEmpty() recorded an issue at P.swift:4:5: Expectation failed: (x → 1) == 2
✘ Test parsesEmpty() failed after 0.001 seconds with 1 issue.
✘ Test run with 3 tests failed after 0.1 seconds with 1 issue."
out="$(summarize_failure 4 1)"
check "swift testing: issue" "$out" "  ✘ Test parsesEmpty() recorded an issue at P.swift:4:5"
check "swift testing: last started" "$out" "  last started: ◇ Test parsesEmpty() started."

# --- a Swift Testing crash
lane 5 "Swift Testing" "◇ Test run started.
◇ Test first() started.
✔ Test first() passed after 0.001 seconds.
◇ Test crashes() started."
out="$(summarize_failure 5 134)"
check "swift testing crash: signal" "$out" "  killed by signal 6"
check "swift testing crash: last started" "$out" "  last started: ◇ Test crashes() started."

# --- Swift Testing dies after printing only its run banner
lane 6 "Swift Testing" "[0/1] Planning build
◇ Test run started.
↳ Testing Library Version: 1743"
out="$(summarize_failure 6 134)"
check "banner only: no test started" "$out" "  no test started; the lane's last lines:"
check "banner only: log tail" "$out" "    ↳ Testing Library Version: 1743"
check_absent "banner only: banner is no test" "$out" "last started:"

# --- print_summary
: > "$WORK/summary"
out="$(print_summary)"
if [[ -z $out ]]; then echo "ok: nothing failed, no summary"; else note_fail "nothing failed but a summary printed: $out"; fi

reports="$HOME/Library/Logs/DiagnosticReports"
printf 'old report\n' > "$reports/xctest-old.ips"
touch -t 202001010000 "$reports/xctest-old.ips"
touch -t 202001020000 "$WORK/list"
printf 'xctest crash body\n' > "$reports/xctest-2026-10-22.ips"
printf 'helper crash body\n' > "$reports/swiftpm-testing-helper-2026-10-22.ips"
printf 'other body\n' > "$reports/Safari-2026-10-22.ips"
summarize_failure 1 139 > "$WORK/summary"
out="$(print_summary)"
check "print: heading" "$out" "swift-test-sharded: failure summary"
check "print: lane summary" "$out" "  killed by signal 11"
check "print: xctest report" "$out" "xctest crash body"
check "print: helper report" "$out" "helper crash body"
check_absent "print: older report" "$out" "old report"
check_absent "print: another process" "$out" "other body"

if ((FAILURES > 0)); then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "all summary checks passed"
