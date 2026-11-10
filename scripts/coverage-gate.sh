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
# `scripts/coverage-gate.sh --packages` prints the whole packages SHARD
# selects.
#
# The split: packages dealt heaviest first, each to the shard with the least
# weight so far (ties to the lower shard), so watchtower/cmd, the heaviest,
# opens shard 1. A package weighs its CI seconds in COVER_WEIGHTS (cmd:
# CMD_WEIGHT), else COVER_WEIGHT_DEFAULT. To rebalance, read the per-package
# seconds off a go-test log ("ok <pkg> <s>s") and update the list; a package
# new to the module needs nothing.
#
# SPREAD_PKG (internal/db) is not dealt: every shard runs its K-th slice of
# the package's tests and writes the profile to COVER_OUT as
# <pkg>.<K>of<N>.cov, and `coverage-gate.sh --merge <dir>` (CI's go-coverage
# job, over every shard's profiles) merges them and checks the package's
# threshold. A shard does not check it.
#
# Compatible with bash 3.2 (macOS) — no associative arrays.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST_ONLY=0
MERGE_DIR=""
if [[ "${1:-}" == "--packages" ]]; then
    LIST_ONLY=1
    shift
elif [[ "${1:-}" == "--merge" ]]; then
    MERGE_DIR="${2:?--merge needs a directory}"
    MERGE_DIR="$(cd "$MERGE_DIR" && pwd)"
    shift 2
fi
THRESHOLDS_FILE="${1:-$ROOT/coverage.thresholds}"
SHARD="${SHARD:-}"
COVER_OUT="${COVER_OUT:-$ROOT/coverage-out}"
TEST_STATUS=0

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
# top-level test names, next to the rest of the tree; the slices' cover
# profiles are merged into the one percentage the gate checks. internal/db
# runs the same way (DB_SHARDS) when one process runs it all; it is CPU-bound
# on a 4-vCPU runner (316 s alone, 233 s as three slices on one, 2026-11-10),
# hence SPREAD_PKG across the shards.
CMD_PKG=watchtower/cmd
CMD_SHARDS="${CMD_SHARDS:-4}"
SPREAD_PKG=watchtower/internal/db
DB_SHARDS="${DB_SHARDS:-3}"

# Merges cover profiles (stdin, "mode:" lines included) into go test's own
# "ok <pkg> … coverage: X% of statements" line: a block counts as covered
# when any profile ran it.
merged_line() {
    awk -v pkg="$1" -v n="$2" '
        /^mode:/ { next }
        { stmts[$1] = $2; if ($3 > 0) hit[$1] = 1 }
        END {
            for (b in stmts) { total += stmts[b]; if (b in hit) covered += stmts[b] }
            printf "ok  \t%s\t(%d shards)\tcoverage: %.1f%% of statements\n", pkg, n, total ? 100 * covered / total : 0
        }'
}

if [[ -n "$MERGE_DIR" ]]; then
    base="$(echo "$SPREAD_PKG" | tr '/' '_')"
    files=("$MERGE_DIR"/"$base".*of*.cov)
    if [[ ! -f "${files[0]}" ]]; then
        echo "coverage-gate: no $SPREAD_PKG profiles in $MERGE_DIR" >&2
        exit 1
    fi
    n="${files[0]##*of}"
    n="${n%.cov}"
    for ((k = 1; k <= n; k++)); do
        if [[ ! -f "$MERGE_DIR/$base.${k}of$n.cov" ]]; then
            echo "coverage-gate: $SPREAD_PKG slice ${k}of$n missing from $MERGE_DIR" >&2
            exit 1
        fi
    done
    if [[ ${#files[@]} -ne $n ]]; then
        echo "coverage-gate: $SPREAD_PKG profiles in $MERGE_DIR are not one set of $n: ${files[*]}" >&2
        exit 1
    fi
    MY_PKGS="$SPREAD_PKG"
    OUTPUT="$(cat "${files[@]}" | merged_line "$SPREAD_PKG" "$n")"
else

# CI seconds per package (go-test log, 2026-11-10, every package on one
# runner). CMD_WEIGHT is cmd's share in the same units, fitted to a sharded
# run (2026-11-10: cmd's slices took ~100 s of wall where weight 560 of other
# packages took ~190 s), plus make test-scripts, which CI runs in cmd's shard:
# the heaviest, so shard 1.
CMD_WEIGHT=350
COVER_WEIGHTS="automations 125 transporttest 70 daemon 69 codex 35 jira 31 chat 27 confluenceedit 24 kb 24 sync 22 tools 22 ideas 17 automations/builtin 15 memory 15 hub/slices/sources 14 ai 13 hub 12 agentlogdb 12 agentlog 12 coach 11 sessioncleanup 10"
COVER_WEIGHT_DEFAULT=3

ALL_PKGS="$(go list ./...)"
if [[ -z "$ALL_PKGS" ]]; then
    echo "coverage-gate: go list ./... listed no packages" >&2
    exit 1
fi
MY_PKGS="$(echo "$ALL_PKGS" | awk -v shard="$SHARD" -v cmd="$CMD_PKG" -v cmdw="$CMD_WEIGHT" -v spread="$SPREAD_PKG" -v weights="$COVER_WEIGHTS" -v dflt="$COVER_WEIGHT_DEFAULT" '
    { pkgs[NR] = $0 }
    END {
        if (shard == "") { for (i = 1; i <= NR; i++) print pkgs[i]; exit }
        if (split(shard, kn, "/") != 2 || kn[1] !~ /^[0-9]+$/ || kn[2] !~ /^[0-9]+$/ || kn[1] < 1 || kn[1] > kn[2]) {
            print "coverage-gate: SHARD must be K/N with 1 <= K <= N, got " shard > "/dev/stderr"; exit 1 }
        k = kn[1] + 0; n = kn[2] + 0
        if (n == 1) { for (i = 1; i <= NR; i++) print pkgs[i]; exit }
        nw = split(weights, ws, " ")
        for (j = 1; j < nw; j += 2) w["watchtower/internal/" ws[j]] = ws[j + 1] + 0
        w[cmd] = cmdw
        # Heaviest first; equal weights keep go list order (stable insertion).
        m = 0
        for (i = 1; i <= NR; i++) {
            p = pkgs[i]
            if (p == spread) continue
            pw = (p in w) ? w[p] : dflt
            for (j = m; j > 0 && wt[j] < pw; j--) { order[j + 1] = order[j]; wt[j + 1] = wt[j] }
            order[j + 1] = p; wt[j + 1] = pw; m++
        }
        for (i = 1; i <= m; i++) {
            best = 1
            for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
            load[best] += wt[i]
            if (best == k) print order[i]
        }
    }')"

# This shard's slice of SPREAD_PKG ("K N"), when the run is sharded.
SPREAD_SLICE=""
if [[ -n "$SHARD" && "${SHARD##*/}" != 1 ]] && echo "$ALL_PKGS" | grep -qxF "$SPREAD_PKG"; then
    SPREAD_SLICE="${SHARD%%/*} ${SHARD##*/}"
fi

if [[ $LIST_ONLY -eq 1 ]]; then
    if [[ -n "$MY_PKGS" ]]; then echo "$MY_PKGS"; fi
    exit 0
fi
if [[ -z "$MY_PKGS" && -z "$SPREAD_SLICE" ]]; then
    echo "coverage-gate: shard $SHARD has no packages" >&2
    exit 1
fi

# The packages run as slices here ("pkg:slices:only" words, only = the one
# slice index this run takes, or "all"), and the rest.
MY_SPLITS=""
REST_PKGS="$MY_PKGS"
for spec in "$CMD_PKG:$CMD_SHARDS" "$SPREAD_PKG:$DB_SHARDS"; do
    pkg="${spec%%:*}"
    if echo "$MY_PKGS" | grep -qxF "$pkg"; then
        MY_SPLITS="$MY_SPLITS $spec:all"
        REST_PKGS="$(echo "$REST_PKGS" | grep -vxF "$pkg" || true)"
    fi
done
if [[ -n "$SPREAD_SLICE" ]]; then
    read -r sk sn <<< "$SPREAD_SLICE"
    MY_SPLITS="$MY_SPLITS $SPREAD_PKG:$sn:$((sk - 1))"
    rm -rf "$COVER_OUT"
    mkdir -p "$COVER_OUT"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

slice_dir() { echo "$WORK/split-$(echo "$1" | tr '/' '_')"; }
# Whether slice $2 of spec $1 runs here.
runs_slice() { local only="${1##*:}"; [[ "$only" == all || "$only" == "$2" ]]; }

for spec in $MY_SPLITS; do
    pkg="${spec%%:*}"
    dir="$(slice_dir "$pkg")"
    mkdir -p "$dir"
    # Also compiles the cover-instrumented test binary once, so the slices
    # below reuse it from the build cache instead of each compiling it.
    if ! go test -cover -list '.*' "$pkg" > "$dir/list" 2>&1; then
        cat "$dir/list"
        echo "coverage-gate: listing $pkg tests failed — see output above" >&2
        exit 1
    fi
    grep -E '^(Test|Fuzz|Example)' "$dir/list" > "$dir/names" || true
    if [[ ! -s "$dir/names" ]]; then
        echo "coverage-gate: no tests listed in $pkg" >&2
        exit 1
    fi
done

# -timeout 20m: with coverage on a CI runner, unsharded watchtower/cmd took
# ~595-601 s, right at go test's default 10m per-package limit.
pids=()
if [[ -n "$REST_PKGS" ]]; then
    # shellcheck disable=SC2086 # one word per package
    go test $REST_PKGS -cover -timeout 20m > "$WORK/rest.log" 2>&1 &
    pids+=($!)
fi
for spec in $MY_SPLITS; do
    pkg="${spec%%:*}"
    n="${spec#*:}"
    n="${n%%:*}"
    dir="$(slice_dir "$pkg")"
    for ((i = 0; i < n; i++)); do
        runs_slice "$spec" "$i" || continue
        run="^($(awk -v n="$n" -v i="$i" 'NR % n == i' "$dir/names" | paste -sd'|' -))\$"
        go test "$pkg" -run "$run" -coverprofile "$dir/$i.cov" -timeout 20m > "$dir/$i.log" 2>&1 &
        pids+=($!)
    done
done

# Capture without letting `set -e` abort before the output is printed: a
# failing test used to kill the script right here, leaving CI with a bare
# "Error 1" and no indication of WHICH test failed.
TEST_STATUS=0
for pid in "${pids[@]}"; do
    wait "$pid" || TEST_STATUS=$?
done

# The slices' own "ok <pkg>" lines are renamed so the parse below sees only
# the merged figure. A run with one slice of a package (SPREAD_PKG on a shard)
# prints no figure for it: it hands the profile on to --merge.
OUTPUT="$(
    if [[ -n "$REST_PKGS" ]]; then cat "$WORK/rest.log"; fi
    for spec in $MY_SPLITS; do
        pkg="${spec%%:*}"
        n="${spec#*:}"
        n="${n%%:*}"
        dir="$(slice_dir "$pkg")"
        for ((i = 0; i < n; i++)); do
            runs_slice "$spec" "$i" || continue
            shard="$pkg[shard $((i + 1))/$n]"
            sed -e "s|^ok\([[:space:]]*\)$pkg\([[:space:]]\)|ok\1$shard\2|" \
                -e "s|^FAIL\([[:space:]]*\)$pkg\([[:space:]]\)|FAIL\1$shard\2|" "$dir/$i.log"
        done
        if [[ $TEST_STATUS -eq 0 ]]; then
            if [[ "${spec##*:}" == all ]]; then
                cat "$dir"/*.cov | merged_line "$pkg" "$n"
            else
                only="${spec##*:}"
                cp "$dir/$only.cov" "$COVER_OUT/$(echo "$pkg" | tr '/' '_').$((only + 1))of$n.cov"
            fi
        fi
    done
)"
fi
echo "$OUTPUT"
if [[ -z "$MERGE_DIR" && $TEST_STATUS -ne 0 ]]; then
    echo "coverage-gate: go test failed (exit $TEST_STATUS) — see output above" >&2
    exit "$TEST_STATUS"
fi

# A threshold is this run's when its package ran here (whole), or — in shard
# 1 and in the unsharded run — when the tree has no such package, so that
# "missing from go test output" failure below fires exactly once.
owns_threshold() {
    if echo "$MY_PKGS" | grep -qxF "$1"; then return 0; fi
    if [[ -z "$MERGE_DIR" ]] && [[ -z "$SHARD" || "${SHARD%%/*}" == 1 ]] && ! echo "$ALL_PKGS" | grep -qxF "$1"; then return 0; fi
    return 1
}

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
