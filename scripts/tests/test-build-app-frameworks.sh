#!/bin/bash
# Tests for the dynamic frameworks scripts/build-app.sh embeds (#603: the
# SQLCipher.framework under the GRDB fork):
#   - embed-frameworks copies every *.framework from the SwiftPM bin path into
#     Contents/Frameworks/, adds the @executable_path/../Frameworks rpath once
#     (never twice), and fails when the binary loads an @rpath framework the
#     bin path does not have;
#   - app-codesign signs each embedded framework before the binaries and the
#     bundle (inside out) on both the real-identity branch (hardened runtime,
#     the same identity) and the ad-hoc branch.
#
# Extracts both blocks verbatim (BEGIN/END markers) and runs them in a
# subshell against stubbed swift, otool, install_name_tool, ditto and
# codesign — no build, no real signature. Runs on Linux too.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}
ok() { echo "ok: $1"; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

EMBED_SNIPPET="$WORK_DIR/embed.sh"
SIGN_SNIPPET="$WORK_DIR/sign.sh"
sed -n '/# BEGIN embed-frameworks/,/# END embed-frameworks/p' "$BUILD_APP" > "$EMBED_SNIPPET"
sed -n '/# BEGIN app-codesign/,/# END app-codesign/p' "$BUILD_APP" > "$SIGN_SNIPPET"
if ! grep -q 'Contents/Frameworks' "$EMBED_SNIPPET" || ! grep -q 'Contents/Frameworks' "$SIGN_SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi

# The embed block must run after the binary is copied into the bundle.
copy_line=$(grep -n 'cp "\$BINARY" "\$APP_BUNDLE/Contents/MacOS/WatchtowerDesktop"' "$BUILD_APP" | head -1 | cut -d: -f1)
embed_line=$(grep -n '# BEGIN embed-frameworks' "$BUILD_APP" | cut -d: -f1)
sign_line=$(grep -n '# BEGIN app-codesign' "$BUILD_APP" | cut -d: -f1)
if [ -n "$copy_line" ] && [ "$copy_line" -lt "$embed_line" ] && [ "$embed_line" -lt "$sign_line" ]; then
    ok "embed-frameworks runs after the binary copy and before app-codesign"
else
    note_fail "embed-frameworks order (binary copy $copy_line, embed $embed_line, sign $sign_line)"
fi

STUB_DIR="$WORK_DIR/stub"
BIN_DIR="$WORK_DIR/bin"
LOG="$WORK_DIR/calls.log"
mkdir -p "$STUB_DIR" "$BIN_DIR/SQLCipher.framework/Versions/A"
echo "lib" > "$BIN_DIR/SQLCipher.framework/Versions/A/SQLCipher"

cat > "$STUB_DIR/swift" <<EOF
#!/bin/bash
echo "$BIN_DIR"
EOF
# otool -L lists the binary's dylibs (OTOOL_LIBS); otool -l prints the
# rpaths in OTOOL_RPATHS, one per line.
cat > "$STUB_DIR/otool" <<'EOF'
#!/bin/bash
case "$1" in
    -L)
        echo "$2:"
        for lib in $OTOOL_LIBS; do printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$lib"; done ;;
    -l)
        for p in $OTOOL_RPATHS; do
            printf '          cmd LC_RPATH\n      cmdsize 32\n         path %s (offset 12)\n' "$p"
        done ;;
esac
EOF
cat > "$STUB_DIR/install_name_tool" <<EOF
#!/bin/bash
printf '%s\n' "install_name_tool \$*" >> "$LOG"
EOF
cat > "$STUB_DIR/ditto" <<'EOF'
#!/bin/bash
cp -R "$1" "$2"
EOF
cat > "$STUB_DIR/codesign" <<EOF
#!/bin/bash
printf '%s\n' "codesign \$*" >> "$LOG"
EOF
chmod +x "$STUB_DIR"/*

# run_embed <bundle> <otool -L libs> <rpaths>; prints the exit code.
run_embed() {
    local bundle="$1"
    mkdir -p "$bundle/Contents/MacOS"
    : > "$LOG"
    (
        export PATH="$STUB_DIR:$PATH" OTOOL_LIBS="$2" OTOOL_RPATHS="$3"
        APP_BUNDLE="$bundle"
        # shellcheck disable=SC1090
        source "$EMBED_SNIPPET"
    ) > "$WORK_DIR/embed.out" 2>&1 && echo 0 || echo $?
}

SQLCIPHER_LIB="@rpath/SQLCipher.framework/Versions/A/SQLCipher /usr/lib/libSystem.B.dylib"

# 1. The framework is copied, the rpath added.
APP1="$WORK_DIR/one/Watchtower.app"
rc=$(run_embed "$APP1" "$SQLCIPHER_LIB" "/usr/lib/swift @loader_path")
[ "$rc" = 0 ] && ok "embed succeeds" || { note_fail "embed exit $rc"; cat "$WORK_DIR/embed.out"; }
[ -f "$APP1/Contents/Frameworks/SQLCipher.framework/Versions/A/SQLCipher" ] \
    && ok "SQLCipher.framework copied into Contents/Frameworks" \
    || note_fail "SQLCipher.framework not in Contents/Frameworks"
grep -qF "install_name_tool -add_rpath @executable_path/../Frameworks $APP1/Contents/MacOS/WatchtowerDesktop" "$LOG" \
    && ok "rpath @executable_path/../Frameworks added" \
    || { note_fail "rpath not added"; cat "$LOG"; }

# 2. An rpath already there is not added twice (install_name_tool would fail).
APP2="$WORK_DIR/two/Watchtower.app"
rc=$(run_embed "$APP2" "$SQLCIPHER_LIB" "@loader_path @executable_path/../Frameworks")
[ "$rc" = 0 ] && ok "embed succeeds with the rpath present" || note_fail "embed exit $rc with the rpath present"
grep -q install_name_tool "$LOG" && note_fail "rpath added a second time" || ok "existing rpath left alone"

# 3. A framework the binary loads but the bin path lacks stops the build.
APP3="$WORK_DIR/three/Watchtower.app"
rc=$(run_embed "$APP3" "$SQLCIPHER_LIB @rpath/Missing.framework/Versions/A/Missing" "@loader_path")
[ "$rc" != 0 ] && grep -q "Missing.framework" "$WORK_DIR/embed.out" \
    && ok "a missing @rpath framework is a hard error" \
    || note_fail "a missing @rpath framework did not fail the build (exit $rc)"

# 4. Signing order on both branches: the framework before everything else.
run_sign() {
    local identity="$1"
    : > "$LOG"
    (
        export PATH="$STUB_DIR:$PATH"
        APP_BUNDLE="$APP1" SIGN_IDENTITY="$identity" TIMESTAMP_FLAG="--timestamp"
        PROVISION_PROFILE="" ENTITLEMENTS="$WORK_DIR/base.entitlements"
        SIGNED_CLOUD_ENTITLEMENTS="" ADHOC_REASON="test"
        # shellcheck disable=SC1090
        source "$SIGN_SNIPPET"
    ) > /dev/null 2>&1
}
for identity in "Developer ID Application: Example (ACME000001)" "-"; do
    label=$([ "$identity" = "-" ] && echo "ad-hoc" || echo "real identity")
    run_sign "$identity"
    first=$(head -1 "$LOG")
    case "$first" in
        *"--sign $identity $APP1/Contents/Frameworks/SQLCipher.framework") ok "$label: the framework is signed first" ;;
        *) note_fail "$label: first codesign call is not the framework: $first"; cat "$LOG" ;;
    esac
    last=$(tail -1 "$LOG")
    case "$last" in
        *"$APP1") ok "$label: the bundle is signed last" ;;
        *) note_fail "$label: last codesign call is not the bundle: $last" ;;
    esac
    if [ "$identity" != "-" ]; then
        case "$first" in
            *"--options runtime --timestamp --sign"*) ok "$label: framework gets the hardened runtime and a timestamp" ;;
            *) note_fail "$label: framework signature lacks --options runtime / --timestamp: $first" ;;
        esac
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all framework embedding checks passed"
