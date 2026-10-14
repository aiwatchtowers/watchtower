#!/usr/bin/env bash
# Runs the already-built WatchtowerDesktop test bundle as SHARDS concurrent
# xctest processes over disjoint round-robin slices of its XCTest classes,
# next to one `swift test` process for the Swift Testing tests, then the
# timing-bound classes (SERIAL_CLASSES) alone.
#
# Why: the suite is ~7 000 short tests (~43 ms each, measured 2026-10-13) run
# serially in one xctest process, ~5 min on a CI runner. `swift test --parallel`
# is no answer: it spawns one process per test case and took 19 min. A few
# class-level shards keep one process per slice, so a class's tests still run
# together and in order. The shards call xctest directly, not `swift test`:
# every SwiftPM process opens .build/build.db at start, even with
# --skip-build, and concurrent ones fail on its lock ("no tests found").
#
# Every process runs under a watchdog (LANE_TIMEOUT seconds, default 600): a
# hung one has its log printed — its last "started" line names the test — and
# its process group killed, instead of the CI step timing out with no log.
#
# Usage: scripts/swift-test-sharded.sh [SHARDS]   (default 3; build first with
# `swift build --build-tests`). Each process's log is printed in full
# afterwards; the exit status is non-zero when any of them fails.
#
# Compatible with bash 3.2 (macOS).

set -euo pipefail

SHARDS="${1:-3}"
if ! [[ $SHARDS =~ ^[1-9][0-9]*$ ]]; then
    echo "swift-test-sharded: SHARDS must be a positive integer, got '$SHARDS'" >&2
    exit 2
fi
LANE_TIMEOUT="${LANE_TIMEOUT:-600}"

# Classes that assert how fast the CPU does something: they run after the
# shards, alone, since three concurrent shards share the runner's cores
# (CommentAnchorTests measured 4.2 s against its 5 s bound on 2026-10-14).
# A bounded-wait assertion ("does not hang past N s") stays in the shards.
SERIAL_CLASSES=(
    WatchtowerCoreTests.CommentAnchorTests
    WatchtowerCoreTests.WorkbenchCodeIndexTests
    WatchtowerDesktopTests.OwnerAskReviewPerformanceTests
    WatchtowerDesktopTests.TextRenderingBenchmarkTests
)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/WatchtowerDesktop"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BUNDLE="$(swift build --show-bin-path)/WatchtowerDesktopPackageTests.xctest"
if [[ ! -d "$BUNDLE" ]]; then
    echo "swift-test-sharded: no test bundle at $BUNDLE — run swift build --build-tests first" >&2
    exit 1
fi
if ! swift test list --skip-build > "$WORK/list" 2> "$WORK/list.err"; then
    cat "$WORK/list.err" >&2
    echo "swift-test-sharded: listing the tests failed" >&2
    exit 1
fi
# Target.Class/test -> Target.Class. A Swift Testing id carries its
# function's parentheses (Target.Suite/name()); an XCTest id never does.
grep -v '(' "$WORK/list" | cut -d/ -f1 | sort -u > "$WORK/all-classes" || true
if [[ ! -s "$WORK/all-classes" ]]; then
    echo "swift-test-sharded: no XCTest classes listed" >&2
    exit 1
fi
printf '%s\n' "${SERIAL_CLASSES[@]}" | sort -u > "$WORK/serial"
# A renamed or deleted class must not silently drop out of the run.
missing="$(comm -23 "$WORK/serial" "$WORK/all-classes")"
if [[ -n "$missing" ]]; then
    echo "swift-test-sharded: SERIAL_CLASSES names classes the bundle does not have: $missing" >&2
    exit 1
fi
comm -23 "$WORK/all-classes" "$WORK/serial" > "$WORK/classes"

# Each background job gets its own process group, so the watchdog can kill a
# hung lane together with the processes it started (xcrun -> xctest,
# swift test -> swift-package -> swiftpm-testing).
set -m
names=()
pids=()
status=0

# Starts "$@" as the next lane, its output in $WORK/log<lane>.
start_lane() {
    local name="$1"
    shift
    "$@" > "$WORK/log${#pids[@]}" 2>&1 &
    names+=("$name")
    pids+=($!)
}

# Waits for the lanes from index $1 on, killing any still running after
# LANE_TIMEOUT, then prints each lane's log and folds its status into $status.
supervise() {
    local first="$1" i rc deadline=$((SECONDS + LANE_TIMEOUT)) running
    while :; do
        running=0
        for ((i = first; i < ${#pids[@]}; i++)); do
            if kill -0 "${pids[$i]}" 2>/dev/null; then running=1; fi
        done
        if [[ $running -eq 0 ]]; then break; fi
        if ((SECONDS >= deadline)); then
            for ((i = first; i < ${#pids[@]}; i++)); do
                if kill -0 "${pids[$i]}" 2>/dev/null; then
                    echo "swift-test-sharded: ${names[$i]} still running after ${LANE_TIMEOUT}s — killing it" >&2
                    kill -TERM -- "-${pids[$i]}" 2>/dev/null || true
                fi
            done
            sleep 5
            for ((i = first; i < ${#pids[@]}; i++)); do
                kill -KILL -- "-${pids[$i]}" 2>/dev/null || true
            done
            break
        fi
        sleep 5
    done
    for ((i = first; i < ${#pids[@]}; i++)); do
        rc=0
        wait "${pids[$i]}" || rc=$?
        # A passing lane folds into a CI log group; a failing one stays open.
        if [[ $rc -eq 0 ]]; then
            echo "::group::${names[$i]} passed"
            cat "$WORK/log$i"
            echo "::endgroup::"
        else
            cat "$WORK/log$i"
            echo "swift-test-sharded: ${names[$i]} failed (exit $rc)" >&2
            status=$rc
        fi
    done
}

# WATCHTOWER_TEST_SHARD: preferences are shared across processes, so the
# test helpers' fixed defaults suites (AppState.isolated) get one per process.
# NSUnbufferedIO: what swift test sets for xctest — a lane that crashes or
# hangs still leaves its last "Test Case ... started" line in its log.
for ((s = 0; s < SHARDS; s++)); do
    classes="$(awk -v n="$SHARDS" -v i="$s" 'NR % n == i' "$WORK/classes" | paste -sd, -)"
    start_lane "XCTest shard $((s + 1))/$SHARDS" \
        env WATCHTOWER_TEST_SHARD="$s" NSUnbufferedIO=YES xcrun xctest -XCTest "$classes" "$BUNDLE"
done
if grep -q '(' "$WORK/list"; then
    start_lane "Swift Testing" \
        env WATCHTOWER_TEST_SHARD="swift-testing" swift test --skip-build --disable-xctest
fi
supervise 0

serial_first=${#pids[@]}
start_lane "XCTest timing-bound classes (alone)" \
    env WATCHTOWER_TEST_SHARD="serial" NSUnbufferedIO=YES xcrun xctest -XCTest "$(paste -sd, - < "$WORK/serial")" "$BUNDLE"
supervise "$serial_first"

exit "$status"
