#!/bin/bash
# Tests for the SDK stamp in build-app.sh (`stamp_sdk_version`, the sdk-stamp
# block): since Xcode 27 SwiftPM records sdk = minos in LC_BUILD_VERSION, which
# makes AppKit run the app in the macOS-14 compatibility look.
#
# Extracts the block verbatim (BEGIN/END markers) and runs it against tiny
# binaries linked here with an explicit -platform_version — no app build.
#
# Covers:
#   - sdk recorded as the minos (the Xcode 27 SwiftPM output) → stamped to the
#     given SDK, minos kept
#   - sdk already right (the CI toolchain)                     → no-op, passes
#   - stamp silently not applied (stubbed vtool)               → build fails
#   - SDK version equal to the minos (degenerate)              → build fails
#   - file without LC_BUILD_VERSION                            → build fails
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"

if ! command -v vtool >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
    echo "skip: vtool/clang not available"
    exit 0
fi

FAILURES=0

note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SNIPPET="$WORK_DIR/snippet.sh"
sed -n '/# BEGIN sdk-stamp/,/# END sdk-stamp/p' "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'stamp_sdk_version()' "$SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi

echo 'int main(void) { return 0; }' > "$WORK_DIR/main.c"

# link <out> <minos> <sdk>
link() {
    clang -arch arm64 -mmacosx-version-min="$2" \
        -Wl,-platform_version,macos,"$2","$3" "$WORK_DIR/main.c" -o "$1"
}

# field <bin> <minos|sdk>
field() {
    vtool -show-build "$1" | awk -v f="$2" '$1 == f { print $2; exit }'
}

# run_stamp <bin> <sdk> [extra PATH dir]  — propagates the function's exit code.
run_stamp() {
    (
        [ -n "${3:-}" ] && PATH="$3:$PATH"
        set -euo pipefail
        # shellcheck disable=SC1090
        . "$SNIPPET"
        stamp_sdk_version "$1" "$2"
    )
}

# --- 1. Xcode 27 SwiftPM output: sdk == minos -------------------------------
link "$WORK_DIR/stale" 14.0 14.0
if run_stamp "$WORK_DIR/stale" 27.0 >/dev/null; then
    if [ "$(field "$WORK_DIR/stale" sdk)" = "27.0" ] && [ "$(field "$WORK_DIR/stale" minos)" = "14.0" ]; then
        echo "ok: stale sdk stamped to 27.0, minos kept"
    else
        note_fail "stale sdk: got minos $(field "$WORK_DIR/stale" minos) sdk $(field "$WORK_DIR/stale" sdk)"
    fi
else
    note_fail "stale sdk: stamp failed"
fi

# --- 2. Already right (Xcode 26.x CI) ----------------------------------------
link "$WORK_DIR/good" 14.0 26.4
if run_stamp "$WORK_DIR/good" 26.4 >/dev/null && [ "$(field "$WORK_DIR/good" sdk)" = "26.4" ]; then
    echo "ok: correct sdk is a no-op"
else
    note_fail "correct sdk: stamp failed or changed the sdk"
fi

# --- 3. Stamp silently not applied -> guard fails the build ------------------
STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"
REAL_VTOOL="$(command -v vtool)"
cat > "$STUB_DIR/vtool" <<EOF
#!/bin/bash
# Pass -show-build through; make -set-build-version copy the input unchanged.
if [ "\$1" = "-set-build-version" ]; then
    out=""; prev=""
    for a in "\$@"; do [ "\$prev" = "-output" ] && out="\$a"; prev="\$a"; done
    cp "\${@: -1}" "\$out"
    exit 0
fi
exec "$REAL_VTOOL" "\$@"
EOF
chmod +x "$STUB_DIR/vtool"
link "$WORK_DIR/unstamped" 14.0 14.0
if OUT=$(run_stamp "$WORK_DIR/unstamped" 27.0 "$STUB_DIR" 2>&1); then
    note_fail "unapplied stamp: build did not fail"
elif [[ "$OUT" == *"compatibility look"* ]]; then
    echo "ok: unapplied stamp fails the build"
else
    note_fail "unapplied stamp: unexpected error: $OUT"
fi

# --- 4. SDK equal to the minos (degenerate) ----------------------------------
link "$WORK_DIR/same" 14.0 14.0
if run_stamp "$WORK_DIR/same" 14.0 >/dev/null 2>&1; then
    note_fail "sdk == minos: build did not fail"
else
    echo "ok: sdk == minos fails the build"
fi

# --- 5. No LC_BUILD_VERSION --------------------------------------------------
echo "not a binary" > "$WORK_DIR/text"
if OUT=$(run_stamp "$WORK_DIR/text" 27.0 2>&1); then
    note_fail "no build version: build did not fail"
elif [[ "$OUT" == *"no LC_BUILD_VERSION"* ]]; then
    echo "ok: missing LC_BUILD_VERSION fails the build"
else
    note_fail "no build version: unexpected error: $OUT"
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) FAILED"
    exit 1
fi
echo "All sdk-stamp tests passed."
