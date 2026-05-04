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

OUTPUT="$(go test ./... -cover 2>&1)"
echo "$OUTPUT"

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
