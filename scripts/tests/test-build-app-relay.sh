#!/bin/bash
# Tests for the Go hub pieces of scripts/build-app.sh (Go hub phase 2, Task 2):
#   - the CLI's go build carries -X watchtower/internal/hub.DefaultRelayOrigin
#     from .env's WATCHTOWER_RELAY_ORIGIN_DEFAULT;
#   - a release build (a version starting with [v]X.Y.Z, prereleases too, not --dev) with it empty is
#     refused before anything is built; --dev and non-release versions may
#     leave it empty;
#   - the CLI-only Mac zip (Watchtower-CLI-<version>-arm64.zip, the signed
#     Contents/MacOS/watchtower) is made only on the signed, notarized branch
#     and lands in checksums.txt.
#
# Extracts the relay-origin-check and cli-zip blocks verbatim and runs them
# against a stubbed `ditto` — never builds, signs or notarizes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

extract() {
    sed -n "/# BEGIN $1/,/# END $1/p" "$BUILD_APP" > "$WORK_DIR/$1.sh"
    if [ ! -s "$WORK_DIR/$1.sh" ]; then
        echo "FAIL: block '$1' not found in build-app.sh — markers moved?"
        exit 1
    fi
}
extract relay-origin-check
extract cli-zip

test_cli_carries_the_relay_origin_ldflag() {
    local builds
    builds=$(grep -E '^[[:space:]]*([A-Z_]+=[^ ]+ )*go build' -A2 "$BUILD_APP" | grep -- '-ldflags' || true)
    if [ -z "$builds" ]; then
        note_fail "ldflag: no go build -ldflags line in build-app.sh"
        return
    fi
    case "$builds" in
        *'-X watchtower/internal/hub.DefaultRelayOrigin=${RELAY_ORIGIN_DEFAULT}'*) ;;
        *) note_fail "ldflag: the CLI build does not pass hub.DefaultRelayOrigin: $builds"; return ;;
    esac
    if ! grep -qE '^RELAY_ORIGIN_DEFAULT="\$\{WATCHTOWER_RELAY_ORIGIN_DEFAULT:-\}"' "$WORK_DIR/relay-origin-check.sh"; then
        note_fail "ldflag: RELAY_ORIGIN_DEFAULT is not read from WATCHTOWER_RELAY_ORIGIN_DEFAULT"
        return
    fi
    echo "ok: test_cli_carries_the_relay_origin_ldflag"
}

# run_check <dev> <version> [origin]: runs the relay-origin-check block; sets
# CHECK_RC and CHECK_OUT.
run_check() {
    CHECK_RC=0
    CHECK_OUT=$(DEV_MODE="$1" VERSION="$2" WATCHTOWER_RELAY_ORIGIN_DEFAULT="${3:-}" \
        bash -c 'set -euo pipefail; . "$0"; echo "origin=$RELAY_ORIGIN_DEFAULT"' "$WORK_DIR/relay-origin-check.sh" 2>&1) || CHECK_RC=$?
}

test_release_build_refuses_an_empty_relay_origin() {
    local v
    for v in 1.2.3 v1.2.3 v1.2.3-rc1; do
        run_check false "$v"
        if [ "$CHECK_RC" -ne 1 ]; then
            note_fail "release: version $v with no origin: want exit 1, got $CHECK_RC: $CHECK_OUT"
            return
        fi
        case "$CHECK_OUT" in
            *"WATCHTOWER_RELAY_ORIGIN_DEFAULT is empty: a release build must pin the relay origin"*) ;;
            *) note_fail "release: message missing: $CHECK_OUT"; return ;;
        esac
    done
    run_check false 1.2.3 https://relay.example.com
    if [ "$CHECK_RC" -ne 0 ] || [ "$CHECK_OUT" != "origin=https://relay.example.com" ]; then
        note_fail "release: a pinned origin was refused or lost: rc=$CHECK_RC $CHECK_OUT"
        return
    fi
    run_check true 1.2.3
    if [ "$CHECK_RC" -ne 0 ]; then
        note_fail "release: --dev with no origin was refused: $CHECK_OUT"
        return
    fi
    run_check false abcdef0-dirty
    if [ "$CHECK_RC" -ne 0 ]; then
        note_fail "release: a non-release version with no origin was refused: $CHECK_OUT"
        return
    fi
    # The check runs before the CLI is built.
    local check_line build_line
    check_line=$(grep -n '# BEGIN relay-origin-check' "$BUILD_APP" | cut -d: -f1)
    build_line=$(grep -nE '^[[:space:]]*([A-Z_]+=[^ ]+ )*go build' "$BUILD_APP" | head -1 | cut -d: -f1)
    if [ "$check_line" -ge "$build_line" ]; then
        note_fail "release: relay-origin-check (line $check_line) comes after the go build (line $build_line)"
        return
    fi
    echo "ok: test_release_build_refuses_an_empty_relay_origin"
}

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/ditto" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$DITTO_LOG"
: > "${@: -1}"
EOF
chmod +x "$STUB_DIR/ditto"

# run_zip <sign-identity> <notarize-profile>: runs the cli-zip block in a
# fresh stage dir; sets ZIP_RC, ZIP_NAME_OUT, ZIP_DIR.
run_zip() {
    ZIP_DIR="$WORK_DIR/stage-$RANDOM"
    mkdir -p "$ZIP_DIR/Watchtower.app/Contents/MacOS"
    printf 'cli' > "$ZIP_DIR/Watchtower.app/Contents/MacOS/watchtower"
    ZIP_RC=0
    ZIP_NAME_OUT=$(cd "$ZIP_DIR" && PATH="$STUB_DIR:$PATH" DITTO_LOG="$ZIP_DIR/ditto.log" \
        SIGN_IDENTITY="$1" NOTARIZE_PROFILE="$2" VERSION=1.2.3 FLAVOR_SUFFIX="" \
        APP_BUNDLE="$ZIP_DIR/Watchtower.app" \
        bash -c 'set -euo pipefail; . "$0" >/dev/null; echo "${CLI_ZIP_NAME}"' "$WORK_DIR/cli-zip.sh" 2>&1) || ZIP_RC=$?
}

test_cli_zip_only_on_the_signed_branch() {
    run_zip "-" ""
    if [ "$ZIP_RC" -ne 0 ] || [ -n "$ZIP_NAME_OUT" ] || [ -e "$ZIP_DIR/ditto.log" ]; then
        note_fail "cli zip: the ad-hoc branch made a zip: rc=$ZIP_RC name=$ZIP_NAME_OUT"
        return
    fi
    run_zip "Developer ID Application: Example" ""
    if [ "$ZIP_RC" -ne 0 ] || [ -n "$ZIP_NAME_OUT" ] || [ -e "$ZIP_DIR/ditto.log" ]; then
        note_fail "cli zip: a signed but not notarized build made a zip: rc=$ZIP_RC name=$ZIP_NAME_OUT"
        return
    fi
    run_zip "Developer ID Application: Example" "example-profile"
    if [ "$ZIP_RC" -ne 0 ] || [ "$ZIP_NAME_OUT" != "Watchtower-CLI-1.2.3-arm64.zip" ]; then
        note_fail "cli zip: the notarized branch: rc=$ZIP_RC name=$ZIP_NAME_OUT"
        return
    fi
    if [ ! -e "$ZIP_DIR/Watchtower-CLI-1.2.3-arm64.zip" ]; then
        note_fail "cli zip: no zip written in the stage dir"
        return
    fi
    if ! grep -qx "$ZIP_DIR/Watchtower.app/Contents/MacOS/watchtower" "$ZIP_DIR/ditto.log"; then
        note_fail "cli zip: ditto was not given the bundle's signed CLI: $(cat "$ZIP_DIR/ditto.log")"
        return
    fi
    if ! grep -qE '^shasum -a 256 "\$DMG_NAME" "\$ZIP_NAME" \$\{CLI_ZIP_NAME:\+"\$CLI_ZIP_NAME"\} > "\$CHECKSUMS"$' "$BUILD_APP"; then
        note_fail "cli zip: checksums.txt does not include the CLI zip"
        return
    fi
    # Made after the app zip's notarization, before the checksums.
    local zip_line notary_line sum_line
    zip_line=$(grep -n '# BEGIN cli-zip' "$BUILD_APP" | cut -d: -f1)
    notary_line=$(grep -n 'xcrun notarytool submit "\$ZIP_NAME"' "$BUILD_APP" | cut -d: -f1)
    sum_line=$(grep -n '^shasum -a 256' "$BUILD_APP" | cut -d: -f1)
    if [ "$zip_line" -le "$notary_line" ] || [ "$zip_line" -ge "$sum_line" ]; then
        note_fail "cli zip: block at line $zip_line is not between the notarization ($notary_line) and the checksums ($sum_line)"
        return
    fi
    echo "ok: test_cli_zip_only_on_the_signed_branch"
}

test_cli_carries_the_relay_origin_ldflag
test_release_build_refuses_an_empty_relay_origin
test_cli_zip_only_on_the_signed_branch

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all build-app relay tests passed"
