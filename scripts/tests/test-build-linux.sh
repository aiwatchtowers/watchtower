#!/bin/bash
# Tests for scripts/build-linux.sh and scripts/check-glibc.sh (Go hub phase 2,
# Task 2): the Linux release tarballs and their glibc floor.
#
# Stubs `go`, `objdump`, `readelf`, `tar` and `sha256sum` on PATH — never
# builds. The `tar` stub records its arguments and hands them to the real tar,
# so the tarball's contents are checked for real. Runs on the dev Mac and in
# the Linux CI job alike.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_LINUX="$SCRIPT_DIR/../build-linux.sh"
CHECK_GLIBC="$SCRIPT_DIR/../check-glibc.sh"
REAL_TAR="$(command -v tar)"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"

# go: `go env GOOS|GOARCH` answers from STUB_GOOS/STUB_GOARCH; `go build`
# records its argv in $STUB_LOG and writes a fake binary to its -o path.
cat > "$STUB_DIR/go" <<'EOF'
#!/bin/bash
case "$1" in
    env)
        case "$2" in
            GOOS) echo "${STUB_GOOS:-linux}" ;;
            GOARCH) echo "${STUB_GOARCH:-arm64}" ;;
            *) exit 1 ;;
        esac
        ;;
    build)
        printf '%s\n' "$@" > "$STUB_LOG.go"
        out=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "-o" ]; then out="$2"; fi
            shift
        done
        [ -n "$out" ] || exit 2
        printf 'fake elf\n' > "$out"
        ;;
    *) exit 1 ;;
esac
EOF

# objdump -T: dynamic symbols carrying the versions in STUB_GLIBC (space-separated).
cat > "$STUB_DIR/objdump" <<'EOF'
#!/bin/bash
echo ""
echo "$2:     file format elf64-littleaarch64"
echo ""
echo "DYNAMIC SYMBOL TABLE:"
for v in ${STUB_GLIBC-GLIBC_2.17 GLIBC_2.34}; do
    echo "0000000000000000      DF *UND*  0000000000000000 ($v) somefunc"
done
EOF

# readelf -d: one NEEDED line per library in STUB_NEEDED (space-separated).
cat > "$STUB_DIR/readelf" <<'EOF'
#!/bin/bash
echo ""
echo "Dynamic section at offset 0x1 contains 30 entries:"
echo "  Tag        Type                         Name/Value"
for l in ${STUB_NEEDED-libcrypto.so.3 libm.so.6 libresolv.so.2 libc.so.6}; do
    echo " 0x0000000000000001 (NEEDED)             Shared library: [$l]"
done
echo " 0x000000000000000c (INIT)               0x4000"
EOF

cat > "$STUB_DIR/tar" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "\$STUB_LOG.tar"
exec "$REAL_TAR" "\$@"
EOF

cat > "$STUB_DIR/sha256sum" <<'EOF'
#!/bin/bash
for f in "$@"; do echo "0000000000000000000000000000000000000000000000000000000000000000  $f"; done
EOF
chmod +x "$STUB_DIR"/*

# run_build <case> <version> [VAR=value ...]: runs build-linux.sh into
# $WORK_DIR/<case>/out with the stubs; output in $WORK_DIR/<case>/output,
# exit code in RUN_RC.
run_build() {
    local name="$1" version="$2"
    shift 2
    mkdir -p "$WORK_DIR/$name"
    RUN_OUT="$WORK_DIR/$name/out"
    RUN_LOG="$WORK_DIR/$name/log"
    RUN_RC=0
    env -u RELAY_ORIGIN PATH="$STUB_DIR:$PATH" STUB_LOG="$RUN_LOG" "$@" \
        bash "$BUILD_LINUX" "$version" "$RUN_OUT" > "$WORK_DIR/$name/output" 2>&1 || RUN_RC=$?
}

test_names_carry_version_and_arch() {
    run_build names 1.2.3-dev STUB_GOARCH=amd64
    if [ "$RUN_RC" -ne 0 ]; then
        note_fail "names: build-linux.sh exit $RUN_RC: $(cat "$WORK_DIR/names/output")"
        return
    fi
    for f in watchtower-1.2.3-dev-linux-amd64.tar.gz watchtower-1.2.3-dev-linux-amd64.tar.gz.sha256; do
        [ -f "$RUN_OUT/$f" ] || { note_fail "names: $f missing (have: $(ls "$RUN_OUT"))"; return; }
    done
    if ! grep -qE '  watchtower-1\.2\.3-dev-linux-amd64\.tar\.gz$' "$RUN_OUT/watchtower-1.2.3-dev-linux-amd64.tar.gz.sha256"; then
        note_fail "names: the .sha256 file does not name the tarball by its bare name: $(cat "$RUN_OUT/watchtower-1.2.3-dev-linux-amd64.tar.gz.sha256")"
        return
    fi
    echo "ok: test_names_carry_version_and_arch"
}

test_glibc_newer_than_floor_fails() {
    local bin="$WORK_DIR/glibc-bin" rc=0 out
    printf 'x' > "$bin"
    out=$(PATH="$STUB_DIR:$PATH" STUB_GLIBC="GLIBC_2.17 GLIBC_2.38 GLIBC_2.34" bash "$CHECK_GLIBC" "$bin" 2.35 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        note_fail "glibc: GLIBC_2.38 passed a 2.35 floor: $out"
        return
    fi
    case "$out" in *GLIBC_2.38*) ;; *) note_fail "glibc: the failure does not name GLIBC_2.38: $out"; return ;; esac
    # The ordering is numeric, not lexical: 2.9 < 2.35.
    rc=0
    out=$(PATH="$STUB_DIR:$PATH" STUB_GLIBC="GLIBC_2.9 GLIBC_2.35 GLIBC_2.2.5" bash "$CHECK_GLIBC" "$bin" 2.35 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        note_fail "glibc: GLIBC_2.35 failed a 2.35 floor: $out"
        return
    fi
    case "$out" in *"check-glibc: max GLIBC_2.35 <= 2.35"*) ;; *) note_fail "glibc: no 'check-glibc: max GLIBC_2.35 <= 2.35' line: $out"; return ;; esac
    # No GLIBC version at all means objdump read nothing: never a pass.
    rc=0
    out=$(PATH="$STUB_DIR:$PATH" STUB_GLIBC="" bash "$CHECK_GLIBC" "$bin" 2.35 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        note_fail "glibc: a binary with no GLIBC versions passed: $out"
        return
    fi
    echo "ok: test_glibc_newer_than_floor_fails"
}

test_unexpected_needed_library_fails() {
    local bin="$WORK_DIR/needed-bin" rc=0 out
    printf 'x' > "$bin"
    out=$(PATH="$STUB_DIR:$PATH" STUB_NEEDED="libcrypto.so.3 libsqlite3.so.0 libc.so.6" bash "$CHECK_GLIBC" "$bin" 2.35 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        note_fail "needed: libsqlite3.so.0 passed: $out"
        return
    fi
    case "$out" in *libsqlite3.so.0*) ;; *) note_fail "needed: the failure does not name libsqlite3.so.0: $out"; return ;; esac
    rc=0
    out=$(PATH="$STUB_DIR:$PATH" STUB_NEEDED="libcrypto.so.3 libm.so.6 libresolv.so.2 libpthread.so.0 libdl.so.2 ld-linux-aarch64.so.1 ld-linux-x86-64.so.2 libc.so.6" bash "$CHECK_GLIBC" "$bin" 2.35 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        note_fail "needed: the allowed set failed: $out"
        return
    fi
    # The build fails with it too, and leaves no tarball.
    run_build needed 1.2.3-dev STUB_NEEDED="libsqlite3.so.0 libc.so.6"
    if [ "$RUN_RC" -eq 0 ]; then
        note_fail "needed: build-linux.sh passed with libsqlite3.so.0"
        return
    fi
    if ls "$RUN_OUT"/*.tar.gz >/dev/null 2>&1; then
        note_fail "needed: a tarball was written after a failed glibc check"
        return
    fi
    echo "ok: test_unexpected_needed_library_fails"
}

test_ldflags_carry_version() {
    run_build ldver 1.2.3-dev
    if [ "$RUN_RC" -ne 0 ]; then
        note_fail "ldflags: exit $RUN_RC: $(cat "$WORK_DIR/ldver/output")"
        return
    fi
    local args
    args=$(cat "$RUN_LOG.go")
    for want in "-X watchtower/cmd.Version=1.2.3-dev" "-X watchtower/cmd.Commit=" "-X watchtower/cmd.BuildDate=" ; do
        case "$args" in *"$want"*) ;; *) note_fail "ldflags: '$want' missing: $args"; return ;; esac
    done
    if ! printf '%s\n' "$args" | grep -qx -- '-tags'; then
        note_fail "ldflags: no -tags argument: $args"
        return
    fi
    if ! printf '%s\n' "$args" | grep -qx 'codegrammars'; then
        note_fail "ldflags: not built with -tags codegrammars: $args"
        return
    fi
    echo "ok: test_ldflags_carry_version"
}

test_ldflags_carry_the_relay_origin() {
    run_build ldrelay v1.2.3 RELAY_ORIGIN=https://relay.example.com
    if [ "$RUN_RC" -ne 0 ]; then
        note_fail "relay: exit $RUN_RC: $(cat "$WORK_DIR/ldrelay/output")"
        return
    fi
    case "$(cat "$RUN_LOG.go")" in
        *"-X watchtower/internal/hub.DefaultRelayOrigin=https://relay.example.com"*) ;;
        *) note_fail "relay: the origin is not in the ldflags: $(cat "$RUN_LOG.go")"; return ;;
    esac
    run_build ldrelaydev 1.2.3-dev
    if [ "$RUN_RC" -ne 0 ]; then
        note_fail "relay: a dev version with no origin failed: $(cat "$WORK_DIR/ldrelaydev/output")"
        return
    fi
    if ! grep -qE -- '-X watchtower/internal/hub\.DefaultRelayOrigin=( |$)' "$RUN_LOG.go"; then
        note_fail "relay: a dev build does not pass an empty origin: $(cat "$RUN_LOG.go")"
        return
    fi
    echo "ok: test_ldflags_carry_the_relay_origin"
}

test_release_build_refuses_an_empty_relay_origin() {
    run_build release v1.2.3
    if [ "$RUN_RC" -ne 1 ]; then
        note_fail "release: want exit 1, got $RUN_RC: $(cat "$WORK_DIR/release/output")"
        return
    fi
    if ! grep -qF "RELAY_ORIGIN is empty: a release build must pin the relay origin" "$WORK_DIR/release/output"; then
        note_fail "release: message missing: $(cat "$WORK_DIR/release/output")"
        return
    fi
    if [ -e "$RUN_LOG.go" ] || ls "$RUN_OUT"/*.tar.gz >/dev/null 2>&1; then
        note_fail "release: it built or wrote a tarball before refusing"
        return
    fi
    echo "ok: test_release_build_refuses_an_empty_relay_origin"
}

test_tarball_holds_only_the_binary() {
    run_build tarball 1.2.3-dev
    if [ "$RUN_RC" -ne 0 ]; then
        note_fail "tarball: exit $RUN_RC: $(cat "$WORK_DIR/tarball/output")"
        return
    fi
    local tarball="$RUN_OUT/watchtower-1.2.3-dev-linux-arm64.tar.gz" listing
    listing=$("$REAL_TAR" -tvzf "$tarball")
    if [ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ')" != "1" ]; then
        note_fail "tarball: want one entry, got: $listing"
        return
    fi
    case "$listing" in
        -rwxr-xr-x*" watchtower") ;;
        *) note_fail "tarball: want one 0755 file named watchtower, got: $listing"; return ;;
    esac
    # Nothing but the tarball and its checksum is left in the output dir.
    local left
    left=$(cd "$RUN_OUT" && ls -A | sort | tr '\n' ' ')
    if [ "$left" != "watchtower-1.2.3-dev-linux-arm64.tar.gz watchtower-1.2.3-dev-linux-arm64.tar.gz.sha256 " ]; then
        note_fail "tarball: the output dir holds more than the release files: $left"
        return
    fi
    echo "ok: test_tarball_holds_only_the_binary"
}

test_refuses_off_linux() {
    run_build offlinux 1.2.3-dev STUB_GOOS=darwin
    if [ "$RUN_RC" -eq 0 ]; then
        note_fail "offlinux: build-linux.sh ran with GOOS=darwin"
        return
    fi
    echo "ok: test_refuses_off_linux"
}

if bash -n "$BUILD_LINUX" && bash -n "$CHECK_GLIBC"; then
    echo "ok: bash -n build-linux.sh check-glibc.sh"
else
    note_fail "bash -n build-linux.sh / check-glibc.sh"
fi

test_names_carry_version_and_arch
test_glibc_newer_than_floor_fails
test_unexpected_needed_library_fails
test_ldflags_carry_version
test_ldflags_carry_the_relay_origin
test_release_build_refuses_an_empty_relay_origin
test_tarball_holds_only_the_binary
test_refuses_off_linux

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all build-linux tests passed"
