#!/bin/bash
# Tests for the app-codesign block of scripts/build-app.sh (mobile hub signing).
#
# Extracts the block verbatim (BEGIN/END markers) and runs it in a subshell
# against a stubbed `codesign` that records its argv — no keychain, no real
# signature, no app build (`make app` stays out of automated verification).
#
# Covers:
#   - real identity + provisioning profile → the bundle is signed with
#     Watchtower-cloud.entitlements and the profile is embedded as
#     Contents/embedded.provisionprofile
#   - ad-hoc path → base entitlements only, no profile embedded (amfid kills
#     an ad-hoc app carrying restricted entitlements)
#   - real identity without a profile → base entitlements and the warning
#     "hub disabled: no provisioning profile"
#   - a profile path that does not exist → hard error, never a silent fallback
#   - BUILD_FLAVOR=corp → the same iCloud container as the default flavor
#   - the cloud entitlements carry the container, CloudKit and push, and stay
#     a superset of the base entitlements
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"
BASE_ENT="$SCRIPT_DIR/../Watchtower.entitlements"
CLOUD_ENT="$SCRIPT_DIR/../Watchtower-cloud.entitlements"
CONTAINER="iCloud.com.aiwatchtowers.watchtower"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

# check <label> <haystack> <needle>
check() {
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *)
            note_fail "$1"
            printf '  wanted substring: %s\n  got:\n%s\n' "$3" "$2"
            ;;
    esac
}

# check_absent <label> <haystack> <needle>
check_absent() {
    case "$2" in
        *"$3"*)
            note_fail "$1"
            printf '  unexpected substring: %s\n  got:\n%s\n' "$3" "$2"
            ;;
        *) echo "ok: $1" ;;
    esac
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SNIPPET="$WORK_DIR/snippet.sh"
sed -n '/# BEGIN app-codesign/,/# END app-codesign/p' "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'codesign' "$SNIPPET"; then
    echo "FAIL: app-codesign extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"
CODESIGN_LOG="$WORK_DIR/codesign.log"
cat > "$STUB_DIR/codesign" <<EOF
#!/bin/bash
printf '%s\n' "codesign \$*" >> "$CODESIGN_LOG"
EOF
chmod +x "$STUB_DIR/codesign"

PROFILE="$WORK_DIR/acme.provisionprofile"
printf 'fake profile bytes\n' > "$PROFILE"

IDENTITY='Developer ID Application: Acme Corp (ACME000001)'

# run_case <sign_identity> <profile path or empty> <flavor or empty>
# Runs the snippet in a fresh fake bundle; prints the snippet's output, then
# the recorded codesign argv. Propagates the snippet's exit code.
run_case() {
    rm -rf "$WORK_DIR/stage"
    mkdir -p "$WORK_DIR/stage/Watchtower.app/Contents/MacOS"
    : > "$CODESIGN_LOG"
    local rc=0
    # shellcheck disable=SC2034 # read by the sourced snippet
    (
        PATH="$STUB_DIR:$PATH"
        PROJECT_ROOT="$WORK_DIR"
        APP_BUNDLE="$WORK_DIR/stage/Watchtower.app"
        ENTITLEMENTS="$BASE_ENT"
        ENTITLEMENTS_CLOUD="$CLOUD_ENT"
        SIGN_IDENTITY="$1"
        WATCHTOWER_PROVISION_PROFILE="$2"
        FLAVOR="$3"
        ADHOC_REASON="test reason"
        TIMESTAMP_FLAG=""
        set -euo pipefail
        # shellcheck disable=SC1090
        . "$SNIPPET"
    ) 2>&1 || rc=$?
    echo "--- codesign calls"
    cat "$CODESIGN_LOG"
    return "$rc"
}

# bundle_sign_line — the codesign call that signs the .app itself.
bundle_sign_line() {
    grep -E 'Watchtower\.app$' "$CODESIGN_LOG" || true
}

EMBEDDED="$WORK_DIR/stage/Watchtower.app/Contents/embedded.provisionprofile"

# --- 1. Real identity + profile → cloud entitlements, profile embedded ------
OUT=$(run_case "$IDENTITY" "$PROFILE" "")
LINE=$(bundle_sign_line)
check "real identity + profile signs the bundle with the cloud entitlements" "$LINE" "--entitlements $CLOUD_ENT"
check "real identity + profile signs with the real identity" "$LINE" "--sign $IDENTITY"
if [ -f "$EMBEDDED" ] && cmp -s "$PROFILE" "$EMBEDDED"; then
    echo "ok: profile embedded as Contents/embedded.provisionprofile"
else
    note_fail "profile embedded as Contents/embedded.provisionprofile"
fi
check "real identity + profile names the embedded profile" "$OUT" "Embedded provisioning profile"
check_absent "the Go binary never gets the cloud entitlements" \
    "$(grep 'MacOS/watchtower$' "$CODESIGN_LOG" || true)" "Watchtower-cloud"

# A relative profile path resolves against the project root.
OUT=$(run_case "$IDENTITY" "acme.provisionprofile" "")
check "relative profile path resolves against the project root" "$(bundle_sign_line)" "--entitlements $CLOUD_ENT"

# --- 2. Ad-hoc path → base entitlements only --------------------------------
OUT=$(run_case "-" "$PROFILE" "")
check_absent "ad-hoc never uses the cloud entitlements" "$OUT" "Watchtower-cloud.entitlements"
check "ad-hoc bundle signs with the base entitlements" "$(bundle_sign_line)" "--entitlements $BASE_ENT"
if [ -e "$EMBEDDED" ]; then
    note_fail "ad-hoc embeds no provisioning profile"
else
    echo "ok: ad-hoc embeds no provisioning profile"
fi

# --- 3. Real identity without a profile → base + warning --------------------
OUT=$(run_case "$IDENTITY" "" "")
check "no profile signs the bundle with the base entitlements" "$(bundle_sign_line)" "--entitlements $BASE_ENT"
check_absent "no profile never uses the cloud entitlements" "$OUT" "Watchtower-cloud.entitlements"
check "no profile warns the hub is disabled" "$OUT" "hub disabled: no provisioning profile"
if [ -e "$EMBEDDED" ]; then
    note_fail "no profile embeds nothing"
else
    echo "ok: no profile embeds nothing"
fi

# --- 4. Profile set but missing → hard error --------------------------------
RC=0
OUT=$(run_case "$IDENTITY" "$WORK_DIR/missing.provisionprofile" "") || RC=$?
if [ "$RC" -ne 0 ]; then
    echo "ok: a missing profile file fails the build"
else
    note_fail "a missing profile file fails the build (got rc=0)"
fi
check "missing-profile error names the variable" "$OUT" "WATCHTOWER_PROVISION_PROFILE"
check_absent "missing profile signs nothing" "$OUT" "Watchtower.app"

# --- 5. BUILD_FLAVOR=corp → the same container ------------------------------
OUT=$(run_case "$IDENTITY" "$PROFILE" "corp")
CORP_LINE=$(bundle_sign_line)
check "corp flavor signs with the same cloud entitlements" "$CORP_LINE" "--entitlements $CLOUD_ENT"
CORP_ENT=$(printf '%s\n' "$CORP_LINE" | sed -E 's/.*--entitlements ([^ ]+) .*/\1/')
CORP_CONTAINER=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-identifiers:0' "$CORP_ENT" 2>&1 || true)
check "corp flavor's container is $CONTAINER" "$CORP_CONTAINER" "$CONTAINER"

# --- 6. Cloud entitlements content ------------------------------------------
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || echo "<missing>"; }
if plutil -lint "$CLOUD_ENT" >/dev/null; then
    echo "ok: cloud entitlements are a valid plist"
else
    note_fail "cloud entitlements are a valid plist"
fi
check "cloud entitlements: the one container" \
    "$(pb 'com.apple.developer.icloud-container-identifiers:0' "$CLOUD_ENT")" "$CONTAINER"
check_absent "cloud entitlements: exactly one container" \
    "$(pb 'com.apple.developer.icloud-container-identifiers:1' "$CLOUD_ENT")" "iCloud."
check "cloud entitlements: CloudKit service" \
    "$(pb 'com.apple.developer.icloud-services:0' "$CLOUD_ENT")" "CloudKit"
check "cloud entitlements: aps-environment production" \
    "$(pb 'com.apple.developer.aps-environment' "$CLOUD_ENT")" "production"
BASE_KEYS=$(/usr/libexec/PlistBuddy -c 'Print' "$BASE_ENT" | sed -nE 's/^[[:space:]]+([^ ]+) = .*/\1/p')
if [ -z "$BASE_KEYS" ]; then
    note_fail "base entitlements parsed to no keys"
fi
for key in $BASE_KEYS; do
    if [ "$(pb "$key" "$BASE_ENT")" = "$(pb "$key" "$CLOUD_ENT")" ]; then
        echo "ok: cloud entitlements keep base key $key"
    else
        note_fail "cloud entitlements keep base key $key with the same value"
    fi
done

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) FAILED"
    exit 1
fi
echo "All cloud-signing tests passed."
