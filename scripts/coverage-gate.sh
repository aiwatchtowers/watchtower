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
# SHARD=K/N (CI's go-test matrix: 1/3, 2/3, 3/3) runs only the K-th of N
# disjoint package slices and checks only the thresholds of the packages it
# ran; a threshold naming no package of the tree fails shard 1. Every
# threshold is a per-package figure, so the N shards together are the same
# gate as one unsharded run. Without SHARD every package runs, as before.
# `scripts/coverage-gate.sh --packages` prints the slice SHARD selects.
#
# The split: watchtower/cmd alone in shard 1 (~a third of the suite's CPU
# time; it runs as CMD_SHARDS processes below), the other packages dealt over
# shards 2..N heaviest first, each to the shard with the least weight so far
# (ties to the lower shard). A package weighs its CI seconds in COVER_WEIGHTS,
# else COVER_WEIGHT_DEFAULT. To rebalance, read the per-package seconds off a
# go-test log ("ok <pkg> <s>s") and update the list; a package new to the
# module needs nothing.
#
# Compatible with bash 3.2 (macOS) — no associative arrays.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST_ONLY=0
if [[ "${1:-}" == "--packages" ]]; then
    LIST_ONLY=1
    shift
fi
THRESHOLDS_FILE="${1:-$ROOT/coverage.thresholds}"
SHARD="${SHARD:-}"

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

# CI seconds per package (go-test log, 2026-11-10, every package on one runner).
COVER_WEIGHTS="db 377 automations 125 transporttest 70 daemon 69 codex 35 jira 31 chat 27 confluenceedit 24 kb 24 sync 22 tools 22 ideas 17 automations/builtin 15 memory 15 hub/slices/sources 14 ai 13 hub 12 agentlogdb 12 agentlog 12 coach 11 sessioncleanup 10"
COVER_WEIGHT_DEFAULT=3

ALL_PKGS="$(go list ./...)"
if [[ -z "$ALL_PKGS" ]]; then
    echo "coverage-gate: go list ./... listed no packages" >&2
    exit 1
fi
MY_PKGS="$(echo "$ALL_PKGS" | awk -v shard="$SHARD" -v cmd="$CMD_PKG" -v weights="$COVER_WEIGHTS" -v dflt="$COVER_WEIGHT_DEFAULT" '
    { pkgs[NR] = $0 }
    END {
        if (shard == "") { for (i = 1; i <= NR; i++) print pkgs[i]; exit }
        if (split(shard, kn, "/") != 2 || kn[1] !~ /^[0-9]+$/ || kn[2] !~ /^[0-9]+$/ || kn[1] < 1 || kn[1] > kn[2]) {
            print "coverage-gate: SHARD must be K/N with 1 <= K <= N, got " shard > "/dev/stderr"; exit 1 }
        k = kn[1] + 0; n = kn[2] + 0
        if (n == 1) { for (i = 1; i <= NR; i++) print pkgs[i]; exit }
        nw = split(weights, ws, " ")
        for (j = 1; j < nw; j += 2) w["watchtower/internal/" ws[j]] = ws[j + 1] + 0
        # Heaviest first; equal weights keep go list order (stable insertion).
        m = 0
        for (i = 1; i <= NR; i++) {
            p = pkgs[i]
            if (p == cmd) { if (k == 1) print p; continue }
            pw = (p in w) ? w[p] : dflt
            for (j = m; j > 0 && wt[j] < pw; j--) { order[j + 1] = order[j]; wt[j + 1] = wt[j] }
            order[j + 1] = p; wt[j + 1] = pw; m++
        }
        for (i = 1; i <= m; i++) {
            best = 2
            for (s = 3; s <= n; s++) if (load[s] < load[best]) best = s
            load[best] += wt[i]
            if (best == k) print order[i]
        }
    }')"

if [[ $LIST_ONLY -eq 1 ]]; then
    if [[ -n "$MY_PKGS" ]]; then echo "$MY_PKGS"; fi
    exit 0
fi
if [[ -z "$MY_PKGS" ]]; then
    echo "coverage-gate: shard $SHARD has no packages" >&2
    exit 1
fi
RUN_CMD=0
if echo "$MY_PKGS" | grep -qxF "$CMD_PKG"; then RUN_CMD=1; fi
REST_PKGS="$(echo "$MY_PKGS" | grep -vxF "$CMD_PKG" || true)"

# A threshold is this run's when its package ran here, or — in shard 1 and in
# the unsharded run — when the tree has no such package, so that "missing from
# go test output" failure below fires exactly once.
owns_threshold() {
    if echo "$MY_PKGS" | grep -qxF "$1"; then return 0; fi
    if [[ -z "$SHARD" || "${SHARD%%/*}" == 1 ]] && ! echo "$ALL_PKGS" | grep -qxF "$1"; then return 0; fi
    return 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ $RUN_CMD -eq 1 ]]; then
    # Also compiles the cover-instrumented test binary once, so the shards
    # below reuse it from the build cache instead of each compiling it.
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
fi

# -timeout 20m: with coverage on a CI runner, unsharded watchtower/cmd took
# ~595-601 s, right at go test's default 10m per-package limit.
pids=()
if [[ -n "$REST_PKGS" ]]; then
    # shellcheck disable=SC2086 # one word per package
    go test $REST_PKGS -cover -timeout 20m > "$WORK/rest.log" 2>&1 &
    pids+=($!)
fi
if [[ $RUN_CMD -eq 1 ]]; then
    for ((i = 0; i < CMD_SHARDS; i++)); do
        run="^($(awk -v n="$CMD_SHARDS" -v i="$i" 'NR % n == i' "$WORK/names" | paste -sd'|' -))\$"
        go test ./cmd -run "$run" -coverprofile "$WORK/cmd$i.cov" -timeout 20m > "$WORK/cmd$i.log" 2>&1 &
        pids+=($!)
    done
fi

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
    if [[ -n "$REST_PKGS" ]]; then cat "$WORK/rest.log"; fi
    if [[ $RUN_CMD -eq 1 ]]; then
    for ((i = 0; i < CMD_SHARDS; i++)); do
        shard="$CMD_PKG[shard $((i + 1))/$CMD_SHARDS]"
        sed -e "s|^ok\([[:space:]]*\)$CMD_PKG\([[:space:]]\)|ok\1$shard\2|" \
            -e "s|^FAIL\([[:space:]]*\)$CMD_PKG\([[:space:]]\)|FAIL\1$shard\2|" "$WORK/cmd$i.log"
    done
    fi
    if [[ $RUN_CMD -eq 1 && $TEST_STATUS -eq 0 ]]; then
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
    owns_threshold "$pkg" || continue

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
