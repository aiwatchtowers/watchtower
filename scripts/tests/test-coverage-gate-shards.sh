#!/bin/bash
# Tests for SHARD=K/N and --merge in scripts/coverage-gate.sh (CI's go-test
# matrix and go-coverage job).
#
# `go` is a stub first in PATH: `go list ./...` prints a fixed module;
# `go test -list` prints TestOne..TestThree; `go test <pkg> -run R
# -coverprofile F` writes a profile covering one block per test R names
# (a.go, b.go, c.go — all three merged: 100 %, one: 33.3 %); any other
# `go test` prints an "ok … coverage: 90.0%" line per package argument.
#
# Covers:
#   - SHARD=1..3/3 deal the module but db: disjoint, union + db = every package
#   - cmd (the heaviest) opens shard 1, alone in this small module
#   - no SHARD and SHARD=1/1 select every package
#   - a malformed SHARD fails
#   - each shard checks only its whole packages' thresholds, runs its db
#     slice into COVER_OUT and checks no db threshold; a threshold for a
#     package the tree lacks fails shard 1 only
#   - --merge over the three db profiles checks db's threshold on the merged
#     figure; a missing slice or a second slice set fails it
#   - the unsharded run checks every threshold, db on its merged slices
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
mkdir -p "$TMP/bin" "$TMP/merge"

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
if [[ " \$* " == *" -list "* ]]; then printf 'TestOne\nTestTwo\nTestThree\n'; exit 0; fi
prev=""; run=""
for a in "\$@"; do
    if [[ "\$prev" == -run ]]; then run="\$a"; fi
    if [[ "\$prev" == -coverprofile ]]; then
        hit() { if [[ "\$run" == *"\$1"* ]]; then echo 1; else echo 0; fi; }
        printf 'mode: set\n%s/a.go:1.1,2.2 1 %s\n%s/b.go:1.1,2.2 1 %s\n%s/c.go:1.1,2.2 1 %s\n' \
            "\$1" "\$(hit TestOne)" "\$1" "\$(hit TestTwo)" "\$1" "\$(hit TestThree)" > "\$a"
        printf 'ok  \t%s\t0.1s\tcoverage: 1.0%% of statements\n' "\$1"
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
gate() { bash "$GATE" "$@" 2>&1; }

# Partition.
all="$(packages "" | sort)"
[[ "$all" == "$(sort "$TMP/pkgs")" ]] || note_fail "no SHARD: expected every package, got: $all"
[[ "$(packages 1/1 | sort)" == "$all" ]] || note_fail "SHARD=1/1: expected every package"
for k in 1 2 3; do packages "$k/3" > "$TMP/s$k"; done
[[ "$( (cat "$TMP/s1" "$TMP/s2" "$TMP/s3"; echo watchtower/internal/db) | sort)" == "$all" ]] \
    || note_fail "shards 1..3/3 plus db are not a partition of the module"
[[ "$(cat "$TMP/s1")" == watchtower/cmd ]] || note_fail "shard 1/3: expected cmd alone, got: $(cat "$TMP/s1")"
for bad in 0/3 4/3 x/3 3 1/2/3; do
    if packages "$bad" > /dev/null 2>&1; then note_fail "SHARD=$bad: expected a failure"; fi
done

# Thresholds per shard; db's profiles handed to --merge.
cat > "$TMP/thresholds" <<'EOF'
watchtower/cmd 40
watchtower/internal/db 90
watchtower/internal/automations 80
EOF
auto_shard=2
if grep -qx watchtower/internal/automations "$TMP/s3"; then auto_shard=3; fi
for k in 1 2 3; do
    out="$(SHARD=$k/3 COVER_OUT="$TMP/out$k" gate "$TMP/thresholds")" || note_fail "shard $k: expected a pass, got: $out"
    [[ "$out" != *"✓ watchtower/internal/db"* && "$out" == *"watchtower/internal/db[shard $k/3]"* ]] \
        || note_fail "shard $k: expected its db slice run and db unchecked, got: $out"
    [[ "$(ls "$TMP/out$k")" == "watchtower_internal_db.${k}of3.cov" ]] \
        || note_fail "shard $k: expected its db profile, got: $(ls "$TMP/out$k")"
    cp "$TMP/out$k"/*.cov "$TMP/merge/"
    if [[ $k -eq 1 ]]; then
        want='✓ watchtower/cmd 100.0% (≥ 40%)'; n=1
    elif [[ $k -eq $auto_shard ]]; then
        want='✓ watchtower/internal/automations 90.0%'; n=1
    else
        want='PASSED'; n=0
    fi
    [[ "$out" == *"$want"* && "$out" == *"PASSED ($n package(s) checked)"* ]] \
        || note_fail "shard $k: expected '$want' and $n checked, got: $out"
done

out="$(gate --merge "$TMP/merge" "$TMP/thresholds")" || note_fail "merge: expected a pass, got: $out"
[[ "$out" == *"✓ watchtower/internal/db 100.0% (≥ 90%)"* && "$out" == *"PASSED (1 package(s) checked)"* ]] \
    || note_fail "merge: expected db alone checked on the merged figure, got: $out"
rm "$TMP/merge/watchtower_internal_db.2of3.cov"
if out="$(gate --merge "$TMP/merge" "$TMP/thresholds")"; then note_fail "merge: a missing slice must fail"; fi
[[ "$out" == *"slice 2of3 missing"* ]] || note_fail "merge: expected the missing-slice line, got: $out"
cp "$TMP/out2"/*.cov "$TMP/merge/"
cp "$TMP/out1/watchtower_internal_db.1of3.cov" "$TMP/merge/watchtower_internal_db.1of2.cov"
if out="$(gate --merge "$TMP/merge" "$TMP/thresholds")"; then note_fail "merge: two slice sets must fail"; fi
rm "$TMP/merge/watchtower_internal_db.1of2.cov"

out="$(gate "$TMP/thresholds")" || note_fail "unsharded: expected a pass, got: $out"
[[ "$out" == *"✓ watchtower/cmd 100.0% (≥ 40%)"* && "$out" == *"✓ watchtower/internal/db 100.0%"* \
    && "$out" == *"PASSED (3 package(s) checked)"* ]] \
    || note_fail "unsharded: expected cmd, db and automations checked, got: $out"

# A threshold for a package the tree lacks.
echo "watchtower/internal/gone 10" >> "$TMP/thresholds"
if out="$(SHARD=1/3 COVER_OUT="$TMP/out1" gate "$TMP/thresholds")"; then
    note_fail "shard 1: a threshold for a missing package must fail"
fi
[[ "$out" == *"internal/gone listed in thresholds but missing"* ]] || note_fail "shard 1: expected the missing-package line, got: $out"
for k in 2 3; do
    out="$(SHARD=$k/3 COVER_OUT="$TMP/out$k" gate "$TMP/thresholds")" || note_fail "shard $k: a missing package fails shard 1 only, got: $out"
done
out="$(gate --merge "$TMP/merge" "$TMP/thresholds")" || note_fail "merge: a missing package fails shard 1 only, got: $out"
if out="$(gate "$TMP/thresholds")"; then
    note_fail "unsharded: a threshold for a missing package must fail"
fi
[[ "$out" == *"internal/gone listed in thresholds but missing"* ]] || note_fail "unsharded: expected the missing-package line, got: $out"

if [[ $FAILURES -ne 0 ]]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "PASS: coverage-gate shards"
