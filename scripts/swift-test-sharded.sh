#!/usr/bin/env bash
# Runs the already-built WatchtowerDesktop test bundle as SHARDS concurrent
# xctest processes over disjoint round-robin slices of its XCTest classes,
# next to one `swift test` process for the Swift Testing tests.
#
# Why: the suite is ~7 000 short tests (~43 ms each, measured 2026-10-13) run
# serially in one xctest process, ~5 min on a CI runner. `swift test --parallel`
# is no answer: it spawns one process per test case and took 19 min. A few
# class-level shards keep one process per slice, so a class's tests still run
# together and in order. The shards call xctest directly, not `swift test`:
# every SwiftPM process opens .build/build.db at start, even with
# --skip-build, and concurrent ones fail on its lock ("no tests found").
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
grep -v '(' "$WORK/list" | cut -d/ -f1 | sort -u > "$WORK/classes" || true
if [[ ! -s "$WORK/classes" ]]; then
    echo "swift-test-sharded: no XCTest classes listed" >&2
    exit 1
fi

# WATCHTOWER_TEST_SHARD: preferences are shared across processes, so the
# test helpers' fixed defaults suites (AppState.isolated) get one per process.
names=()
pids=()
for ((i = 0; i < SHARDS; i++)); do
    classes="$(awk -v n="$SHARDS" -v i="$i" 'NR % n == i' "$WORK/classes" | paste -sd, -)"
    WATCHTOWER_TEST_SHARD="$i" xcrun xctest -XCTest "$classes" "$BUNDLE" > "$WORK/log$i" 2>&1 &
    names+=("XCTest shard $((i + 1))/$SHARDS")
    pids+=($!)
done
if grep -q '(' "$WORK/list"; then
    WATCHTOWER_TEST_SHARD="swift-testing" swift test --skip-build --disable-xctest > "$WORK/log$SHARDS" 2>&1 &
    names+=("Swift Testing")
    pids+=($!)
fi

status=0
for ((i = 0; i < ${#pids[@]}; i++)); do
    rc=0
    wait "${pids[$i]}" || rc=$?
    # A passing process folds into a CI log group; a failing one stays open.
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
exit "$status"
