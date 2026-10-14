#!/usr/bin/env bash
# Runs the already-built WatchtowerDesktop test bundle as SHARDS concurrent
# `swift test --skip-build` processes over disjoint round-robin slices of its
# test classes (XCTest classes and Swift Testing suites alike).
#
# Why: the suite is ~7 000 short tests (~43 ms each, measured 2026-10-13) run
# serially in one xctest process, ~5 min on a CI runner. `swift test --parallel`
# is no answer: it spawns one process per test case and took 19 min. A few
# class-level shards keep one process per slice, so a class's tests still run
# together and in order.
#
# Usage: scripts/swift-test-sharded.sh [SHARDS]   (default 3; build first with
# `swift build --build-tests`). Each shard's log is printed in full afterwards;
# the exit status is non-zero when any shard fails.
#
# Compatible with bash 3.2 (macOS).

set -euo pipefail

SHARDS="${1:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/WatchtowerDesktop"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! swift test list --skip-build --ignore-lock > "$WORK/list" 2> "$WORK/list.err"; then
    cat "$WORK/list.err" >&2
    echo "swift-test-sharded: listing the tests failed" >&2
    exit 1
fi
# Target.Class/test -> Target.Class, regex-escaped for --filter.
cut -d/ -f1 "$WORK/list" | sort -u | sed 's/[][\.^$*+?(){}|]/\\&/g' > "$WORK/classes"
if [[ ! -s "$WORK/classes" ]]; then
    echo "swift-test-sharded: no tests listed" >&2
    exit 1
fi

pids=()
for ((i = 0; i < SHARDS; i++)); do
    filter="^($(awk -v n="$SHARDS" -v i="$i" 'NR % n == i' "$WORK/classes" | paste -sd'|' -))/"
    # --ignore-lock: SwiftPM otherwise serialises every process on the
    # .build lock; with --skip-build the shards only read the built bundle.
    swift test --skip-build --ignore-lock --filter "$filter" > "$WORK/shard$i.log" 2>&1 &
    pids+=($!)
done

status=0
for ((i = 0; i < SHARDS; i++)); do
    rc=0
    wait "${pids[$i]}" || rc=$?
    # A passing shard folds into a CI log group; a failing one stays open.
    if [[ $rc -eq 0 ]]; then
        echo "::group::shard $((i + 1))/$SHARDS passed"
        cat "$WORK/shard$i.log"
        echo "::endgroup::"
    else
        cat "$WORK/shard$i.log"
        echo "swift-test-sharded: shard $((i + 1))/$SHARDS failed (exit $rc)" >&2
        status=$rc
    fi
done
exit "$status"
