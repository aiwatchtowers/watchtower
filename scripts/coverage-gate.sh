#!/usr/bin/env bash
# Coverage gate: runs `go test ./...` with coverage and fails if any
# package listed in coverage.thresholds drops below its declared floor.
#
# Threshold file format (one entry per line, '#' starts a comment):
#   <full-package-path> <percent>
# Example:
#   watchtower/internal/claude 80
#
# A package not listed is unconstrained. A package listed but absent
# from `go test` output (e.g. removed) is reported as a missing package
# and fails the gate so that thresholds stay in sync with the tree.
#
# Compatible with bash 3.2 (macOS) — no associative arrays.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLDS_FILE="${1:-$ROOT/coverage.thresholds}"

if [[ ! -f "$THRESHOLDS_FILE" ]]; then
    echo "coverage-gate: threshold file not found: $THRESHOLDS_FILE" >&2
    exit 2
fi

cd "$ROOT"

# watchtower/cmd is most of the suite's wall-clock: 1 300+ tests, none
# t.Parallel (they share process-global state), so one go test process runs
# them back to back — measured 2026-10-14: ~7 min locally, 7-13 min on a CI
# runner, against ~1 min for every other package together. It runs instead as
# CMD_SHARDS go test processes over disjoint round-robin slices of its
# top-level test names, next to the rest of the tree; the shards' cover
# profiles are merged into the one percentage the gate checks.
CMD_PKG=watchtower/cmd
CMD_SHARDS="${CMD_SHARDS:-4}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Also compiles the cover-instrumented test binary once, so the shards below
# reuse it from the build cache instead of each compiling it.
if ! go test -cover -list '.*' ./cmd > "$WORK/list" 2>&1; then
    cat "$WORK/list"
    echo "coverage-gate: listing $CMD_PKG tests failed — see output above" >&2
    exit 1
fi
grep -E '^(Test|Fuzz|Example)' "$WORK/list" > "$WORK/names" || true
if [[ ! -s "$WORK/names" ]]; then
    echo "coverage-gate: no tests listed in $CMD_PKG" >&2
    exit 1
fi

# -timeout 20m: with coverage on a CI runner, unsharded watchtower/cmd took
# ~595-601 s, right at go test's default 10m per-package limit.
pids=()
go test $(go list ./... | grep -vx "$CMD_PKG") -cover -timeout 20m > "$WORK/rest.log" 2>&1 &
pids+=($!)
for ((i = 0; i < CMD_SHARDS; i++)); do
    run="^($(awk -v n="$CMD_SHARDS" -v i="$i" 'NR % n == i' "$WORK/names" | paste -sd'|' -))\$"
    go test ./cmd -run "$run" -coverprofile "$WORK/cmd$i.cov" -timeout 20m > "$WORK/cmd$i.log" 2>&1 &
    pids+=($!)
done

# Capture without letting `set -e` abort before the output is printed: a
# failing test used to kill the script right here, leaving CI with a bare
# "Error 1" and no indication of WHICH test failed.
TEST_STATUS=0
for pid in "${pids[@]}"; do
    wait "$pid" || TEST_STATUS=$?
done

# The shards' own "ok watchtower/cmd" lines are renamed so the parse below
# sees only the merged figure: a block counts as covered when any shard ran it.
OUTPUT="$(
    cat "$WORK/rest.log"
    for ((i = 0; i < CMD_SHARDS; i++)); do
        shard="$CMD_PKG[shard $((i + 1))/$CMD_SHARDS]"
        sed -e "s|^ok\([[:space:]]*\)$CMD_PKG\([[:space:]]\)|ok\1$shard\2|" \
            -e "s|^FAIL\([[:space:]]*\)$CMD_PKG\([[:space:]]\)|FAIL\1$shard\2|" "$WORK/cmd$i.log"
    done
    if [[ $TEST_STATUS -eq 0 ]]; then
        tail -q -n +2 "$WORK"/cmd*.cov | awk -v pkg="$CMD_PKG" -v n="$CMD_SHARDS" '
            { stmts[$1] = $2; if ($3 > 0) hit[$1] = 1 }
            END {
                for (b in stmts) { total += stmts[b]; if (b in hit) covered += stmts[b] }
                printf "ok  \t%s\t(%d shards)\tcoverage: %.1f%% of statements\n", pkg, n, total ? 100 * covered / total : 0
            }'
    fi
)"
echo "$OUTPUT"
if [[ $TEST_STATUS -ne 0 ]]; then
    echo "coverage-gate: go test failed (exit $TEST_STATUS) — see output above" >&2
    exit "$TEST_STATUS"
fi

# Distil per-package coverage into a "pkg pct" stream.
ACTUAL=$(echo "$OUTPUT" | awk '
    /^ok[[:space:]]/ {
        pkg = $2
        for (i = 3; i <= NF; i++) {
            if ($i == "coverage:") {
                val = $(i+1)
                gsub(/%/, "", val)
                if (val ~ /^[0-9.]+$/) {
                    print pkg, val
                }
                next
            }
        }
    }
')

lookup_actual() {
    local pkg="$1"
    echo "$ACTUAL" | awk -v p="$pkg" '$1 == p { print $2; exit }'
}

failed=0
checked=0

while IFS= read -r raw_line; do
    line="${raw_line%%#*}"
    line="$(echo "$line" | tr -s '\t ' '  ')"
    line="${line# }"
    line="${line% }"
    [[ -z "$line" ]] && continue

    pkg="$(echo "$line" | awk '{print $1}')"
    threshold="$(echo "$line" | awk '{print $2}')"
    if [[ -z "$pkg" || -z "$threshold" ]]; then
        echo "coverage-gate: bad threshold line: $raw_line" >&2
        failed=1
        continue
    fi

    actual="$(lookup_actual "$pkg")"
    if [[ -z "$actual" ]]; then
        echo "coverage-gate: ✗ $pkg listed in thresholds but missing from go test output" >&2
        failed=1
        continue
    fi

    checked=$((checked + 1))

    # Use awk for floating-point comparison.
    if awk -v a="$actual" -v t="$threshold" 'BEGIN { exit !(a < t) }'; then
        echo "coverage-gate: ✗ $pkg coverage ${actual}% < threshold ${threshold}%" >&2
        failed=1
    else
        echo "coverage-gate: ✓ $pkg ${actual}% (≥ ${threshold}%)"
    fi
done < "$THRESHOLDS_FILE"

if [[ $failed -ne 0 ]]; then
    echo
    echo "coverage-gate: FAILED — see ✗ entries above." >&2
    echo "If a package's threshold is no longer realistic, edit $THRESHOLDS_FILE." >&2
    exit 1
fi

echo
echo "coverage-gate: PASSED ($checked package(s) checked)."
