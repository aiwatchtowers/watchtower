#!/bin/bash
# Tests for SHARD=K/N in scripts/coverage-gate.sh (CI's go-test matrix).
#
# `go` is a stub first in PATH: `go list ./...` prints a fixed module;
# `go test -list` prints two test names; a sliced `go test <pkg> -coverprofile F`
# writes a half-covered profile (merged: 50 %); any other `go test` prints an "ok … coverage:
# 90.0%" line per package argument.
#
# Covers:
#   - SHARD=1..3/3 partition the module: disjoint, union = the unsharded list
#   - cmd alone in shard 1; db and automations (the two heaviest) apart
#   - no SHARD and SHARD=1/1 select every package
#   - a malformed SHARD fails
#   - each shard checks only its packages' thresholds; a threshold for a
#     package the tree lacks fails shard 1 only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../coverage-gate.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

if ! bash -n "$GATE"; then
    echo "FAIL: coverage-gate.sh does not parse"
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/coverage-gate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/pkgs" <<'EOF'
watchtower
watchtower/cmd
watchtower/internal/ai
watchtower/internal/automations
watchtower/internal/daemon
watchtower/internal/db
watchtower/internal/kb
watchtower/internal/slack
watchtower/internal/sync
watchtower/internal/transporttest
EOF

cat > "$TMP/bin/go" <<EOF
#!/bin/bash
if [[ "\$1" == list ]]; then cat "$TMP/pkgs"; exit 0; fi
shift
if [[ " \$* " == *" -list "* ]]; then echo TestOne; echo TestTwo; exit 0; fi
prev=""
for a in "\$@"; do
    if [[ "\$prev" == -coverprofile ]]; then
        # A sliced package: block a.go covered, b.go not → 50 %.
        printf 'mode: set\n%s/a.go:1.1,2.2 1 1\n%s/b.go:1.1,2.2 1 0\n' "\$1" "\$1" > "\$a"
        printf 'ok  \t%s\t0.1s\tcoverage: 50.0%% of statements\n' "\$1"
        exit 0
    fi
    prev="\$a"
done
for a in "\$@"; do
    case "\$a" in watchtower*) printf 'ok  \t%s\t0.1s\tcoverage: 90.0%% of statements\n' "\$a" ;; esac
done
EOF
chmod +x "$TMP/bin/go"
export PATH="$TMP/bin:$PATH"

packages() { SHARD="$1" bash "$GATE" --packages; }

# Partition.
all="$(packages "" | sort)"
[[ "$all" == "$(sort "$TMP/pkgs")" ]] || note_fail "no SHARD: expected every package, got: $all"
[[ "$(packages 1/1 | sort)" == "$all" ]] || note_fail "SHARD=1/1: expected every package"
for k in 1 2 3; do packages "$k/3" > "$TMP/s$k"; done
[[ "$(sort "$TMP/s1" "$TMP/s2" "$TMP/s3")" == "$all" ]] || note_fail "shards 1..3/3 are not a partition of the module"
[[ "$(cat "$TMP/s1")" == watchtower/cmd ]] || note_fail "shard 1/3: expected cmd alone, got: $(cat "$TMP/s1")"
if grep -qx watchtower/internal/db "$TMP/s2" && grep -qx watchtower/internal/automations "$TMP/s2"; then
    note_fail "db and automations landed in one shard"
fi
if grep -qx watchtower/internal/db "$TMP/s3" && grep -qx watchtower/internal/automations "$TMP/s3"; then
    note_fail "db and automations landed in one shard"
fi
for bad in 0/3 4/3 x/3 3 1/2/3; do
    if packages "$bad" > /dev/null 2>&1; then note_fail "SHARD=$bad: expected a failure"; fi
done

# Thresholds per shard.
cat > "$TMP/thresholds" <<'EOF'
watchtower/cmd 40
watchtower/internal/db 50
EOF
db_shard=2
grep -qx watchtower/internal/db "$TMP/s3" && db_shard=3
other_shard=$((5 - db_shard))
out="$(SHARD=$db_shard/3 bash "$GATE" "$TMP/thresholds" 2>&1)" || note_fail "shard $db_shard: expected a pass, got: $out"
[[ "$out" == *"✓ watchtower/internal/db 50.0%"* && "$out" == *"PASSED (1 package(s) checked)"* ]] \
    || note_fail "shard $db_shard: expected db alone checked, got: $out"
out="$(SHARD=$other_shard/3 bash "$GATE" "$TMP/thresholds" 2>&1)" || note_fail "shard $other_shard: expected a pass, got: $out"
[[ "$out" == *"PASSED (0 package(s) checked)"* ]] || note_fail "shard $other_shard: expected nothing checked, got: $out"
out="$(SHARD=1/3 bash "$GATE" "$TMP/thresholds" 2>&1)" || note_fail "shard 1: expected a pass, got: $out"
[[ "$out" == *"✓ watchtower/cmd 50.0% (≥ 40%)"* && "$out" == *"PASSED (1 package(s) checked)"* ]] \
    || note_fail "shard 1: expected cmd alone checked, got: $out"
out="$(bash "$GATE" "$TMP/thresholds" 2>&1)" || note_fail "unsharded: expected a pass, got: $out"
[[ "$out" == *"✓ watchtower/cmd 50.0% (≥ 40%)"* && "$out" == *"✓ watchtower/internal/db 50.0%"* && "$out" == *"PASSED (2 package(s) checked)"* ]] \
    || note_fail "unsharded: expected cmd and db checked, got: $out"

echo "watchtower/internal/gone 10" >> "$TMP/thresholds"
if out="$(SHARD=1/3 bash "$GATE" "$TMP/thresholds" 2>&1)"; then
    note_fail "shard 1: a threshold for a missing package must fail"
fi
[[ "$out" == *"internal/gone listed in thresholds but missing"* ]] || note_fail "shard 1: expected the missing-package line, got: $out"
for k in 2 3; do
    out="$(SHARD=$k/3 bash "$GATE" "$TMP/thresholds" 2>&1)" || note_fail "shard $k: a missing package fails shard 1 only, got: $out"
done
if out="$(bash "$GATE" "$TMP/thresholds" 2>&1)"; then
    note_fail "unsharded: a threshold for a missing package must fail"
fi
[[ "$out" == *"internal/gone listed in thresholds but missing"* ]] || note_fail "unsharded: expected the missing-package line, got: $out"

if [[ $FAILURES -ne 0 ]]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "PASS: coverage-gate shards"
