#!/bin/bash
# Tests for scripts/swift-test-sharded.sh's test-bundle lookup (bundle_for)
# and its xctest lanes (xctest_lane), extracted verbatim from the script and
# run against a fake bin dir and a stub xcrun — no build, no xctest.
#
# Covers:
#   - native build (one WatchtowerDesktopPackageTests.xctest) → every class
#     in one xctest call on that bundle
#   - swiftbuild (one <Target>.xctest per test target, the Mac's runners) →
#     one xctest call per target, each on its own bundle with only its classes
#   - the lane passes its shard in WATCHTOWER_TEST_SHARD
#   - a failing first target does not stop the next; the lane returns the
#     first failure's status
#   - a crash (status > 128) ends the lane at its bundle, status kept, so the
#     summary's last started test is the crashed bundle's
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../swift-test-sharded.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

eval "$(sed -n '/^bundle_for() {/,/^}/p; /^xctest_lane() {/,/^}/p' "$SCRIPT")"
if ! declare -F bundle_for >/dev/null || ! declare -F xctest_lane >/dev/null; then
    echo "FAIL: could not extract bundle_for/xctest_lane from $SCRIPT"
    exit 1
fi

# Stub xcrun: logs "shard=<s> <args>" and exits with the code the
# EXIT_<Target> variable names for the bundle it was given (default 0).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xcrun" <<'EOF'
#!/bin/bash
echo "shard=$WATCHTOWER_TEST_SHARD $*" >> "$XCRUN_LOG"
bundle=$(basename "${!#}" .xctest)
code_var="EXIT_$bundle"
exit "${!code_var:-0}"
EOF
chmod +x "$TMP/bin/xcrun"
export PATH="$TMP/bin:$PATH" XCRUN_LOG="$TMP/log"

CLASSES="CoreTests.A,DesktopTests.B,CoreTests.C"

# lane <label> <want status> <want log>
lane() {
    local rc=0 got
    : > "$XCRUN_LOG"
    xctest_lane 2 "$CLASSES" || rc=$?
    got=$(cat "$XCRUN_LOG")
    if [ "$rc" -ne "$2" ]; then
        note_fail "$1: status $rc, want $2"
    elif [ "$got" != "$3" ]; then
        note_fail "$1: calls
$got
want
$3"
    else
        echo "ok: $1"
    fi
}

BIN="$TMP/native"
mkdir -p "$BIN/WatchtowerDesktopPackageTests.xctest"
lane "native: each target on the one combined bundle" 0 \
    "shard=2 xctest -XCTest CoreTests.A,CoreTests.C $BIN/WatchtowerDesktopPackageTests.xctest
shard=2 xctest -XCTest DesktopTests.B $BIN/WatchtowerDesktopPackageTests.xctest"

BIN="$TMP/swiftbuild"
mkdir -p "$BIN/CoreTests.xctest" "$BIN/DesktopTests.xctest"
if [ "$(bundle_for CoreTests)" != "$BIN/CoreTests.xctest" ]; then
    note_fail "swiftbuild: bundle_for CoreTests is $(bundle_for CoreTests)"
fi
lane "swiftbuild: one call per target bundle" 0 \
    "shard=2 xctest -XCTest CoreTests.A,CoreTests.C $BIN/CoreTests.xctest
shard=2 xctest -XCTest DesktopTests.B $BIN/DesktopTests.xctest"

EXIT_CoreTests=1 EXIT_DesktopTests=139 lane "first failure's status, next target still runs" 1 \
    "shard=2 xctest -XCTest CoreTests.A,CoreTests.C $BIN/CoreTests.xctest
shard=2 xctest -XCTest DesktopTests.B $BIN/DesktopTests.xctest"

EXIT_CoreTests=139 lane "a crash ends the lane, its status kept" 139 \
    "shard=2 xctest -XCTest CoreTests.A,CoreTests.C $BIN/CoreTests.xctest"

EXIT_DesktopTests=1 lane "a later failure fails the lane" 1 \
    "shard=2 xctest -XCTest CoreTests.A,CoreTests.C $BIN/CoreTests.xctest
shard=2 xctest -XCTest DesktopTests.B $BIN/DesktopTests.xctest"

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all swift-test-sharded bundle tests passed"
