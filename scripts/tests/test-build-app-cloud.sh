#!/bin/bash
# Tests for mobile hub signing in scripts/build-app.sh: the
# provision-profile-check and app-codesign blocks.
#
# Extracts both blocks verbatim (BEGIN/END markers) and runs them in a
# subshell against a stubbed `security` (which "decodes" a fake profile plist)
# and a stubbed `codesign` that records its argv and keeps a copy of the
# bundle's entitlements — no keychain, no real signature, no app build
# (`make app` stays out of automated verification).
#
# Covers:
#   - real identity + matching profile → the bundle is signed with the cloud
#     entitlements plus com.apple.application-identifier and
#     com.apple.developer.team-identifier taken from the profile, and the
#     profile is embedded as Contents/embedded.provisionprofile
#   - ad-hoc path → base entitlements only, no profile embedded, and a note
#     that the profile is ignored
#   - real identity without a profile → base entitlements and the warning
#     "hub disabled: no provisioning profile"
#   - a profile that is missing, undecodable, for the wrong App ID, or lacks
#     the container, CloudKit, aps-environment or the chosen CloudKit
#     environment → hard error before anything is signed
#   - WATCHTOWER_CLOUDKIT_ENV=Development with a development profile → the
#     bundle is signed for Development (container environment and
#     aps-environment rewritten); an unknown value is a hard error
#   - BUILD_FLAVOR=corp → the signing blocks have no flavor logic and sign
#     with the same container
#   - the cloud entitlements carry the container, CloudKit, Production and
#     push, never a team id, and stay a superset of the base entitlements
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"
BASE_ENT="$SCRIPT_DIR/../Watchtower.entitlements"
CLOUD_ENT="$SCRIPT_DIR/../Watchtower-cloud.entitlements"
CONTAINER="iCloud.com.aiwatchtowers.watchtower"
BUNDLE_ID="com.watchtower.desktop"
TEAM="ACME000001"

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

CHECK_SNIPPET="$WORK_DIR/check.sh"
SIGN_SNIPPET="$WORK_DIR/sign.sh"
sed -n '/# BEGIN provision-profile-check/,/# END provision-profile-check/p' "$BUILD_APP" > "$CHECK_SNIPPET"
sed -n '/# BEGIN app-codesign/,/# END app-codesign/p' "$BUILD_APP" > "$SIGN_SNIPPET"
if ! grep -q 'security cms' "$CHECK_SNIPPET" || ! grep -q 'codesign' "$SIGN_SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi

# The App ID the profile is checked against is the one Info.plist carries.
# shellcheck disable=SC2016 # the literal $BUNDLE_ID in the heredoc is the point
if grep -q "^BUNDLE_ID=\"$BUNDLE_ID\"$" "$BUILD_APP" \
    && grep -A1 '<key>CFBundleIdentifier</key>' "$BUILD_APP" | grep -qF '<string>$BUNDLE_ID</string>'; then
    echo "ok: Info.plist's CFBundleIdentifier is BUNDLE_ID ($BUNDLE_ID)"
else
    note_fail "Info.plist's CFBundleIdentifier is BUNDLE_ID ($BUNDLE_ID)"
fi

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"
CODESIGN_LOG="$WORK_DIR/codesign.log"
SIGNED_ENT="$WORK_DIR/bundle.entitlements"
cat > "$STUB_DIR/codesign" <<EOF
#!/bin/bash
printf '%s\n' "codesign \$*" >> "$CODESIGN_LOG"
ent=""
prev=""
for a in "\$@"; do
    [ "\$prev" = "--entitlements" ] && ent="\$a"
    prev="\$a"
done
case "\${!#}" in
    *Watchtower.app) [ -n "\$ent" ] && cp "\$ent" "$SIGNED_ENT" ;;
esac
exit 0
EOF
# security cms -D -i <file>: the fake profile is already a plain plist.
cat > "$STUB_DIR/security" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "cms -D -i" ] || { echo "unexpected security call: $*" >&2; exit 2; }
if grep -q BROKEN "$4"; then
    echo "security: SecCMSDecoder failed" >&2
    exit 1
fi
cat "$4"
EOF
chmod +x "$STUB_DIR/codesign" "$STUB_DIR/security"

# make_profile <path> <application-identifier> <team id> <container...>
# PROFILE_SERVICES, PROFILE_ENVS (space-separated) and PROFILE_APS shape the
# profile's CloudKit entitlements (defaults: a Developer ID profile —
# CloudKit, Production, production); "none" leaves the key out.
make_profile() {
    local path="$1" app_id="$2" team="$3"
    shift 3
    local containers="" services="" envs="" aps=""
    for c in "$@"; do containers="$containers<string>$c</string>"; done
    local svc_spec="${PROFILE_SERVICES:-CloudKit}" env_spec="${PROFILE_ENVS:-Production}" aps_spec="${PROFILE_APS:-production}"
    if [ "$svc_spec" = "*" ]; then
        services="<key>com.apple.developer.icloud-services</key><string>*</string>"
    elif [ "$svc_spec" != "none" ]; then
        services="<key>com.apple.developer.icloud-services</key><array>"
        for v in $svc_spec; do services="$services<string>$v</string>"; done
        services="$services</array>"
    fi
    if [ "$env_spec" != "none" ]; then
        envs="<key>com.apple.developer.icloud-container-environment</key><array>"
        for v in $env_spec; do envs="$envs<string>$v</string>"; done
        envs="$envs</array>"
    fi
    if [ "$aps_spec" != "none" ]; then
        aps="<key>com.apple.developer.aps-environment</key><string>$aps_spec</string>"
    fi
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Name</key><string>Acme hub profile</string>
    <key>TeamIdentifier</key><array><string>$team</string></array>
    <key>Entitlements</key>
    <dict>
        <key>com.apple.application-identifier</key><string>$app_id</string>
        <key>com.apple.developer.team-identifier</key><string>$team</string>
        <key>com.apple.developer.icloud-container-identifiers</key><array>$containers</array>
        $services
        $envs
        $aps
    </dict>
</dict>
</plist>
EOF
}

PROFILE="$WORK_DIR/acme.provisionprofile"
make_profile "$PROFILE" "$TEAM.$BUNDLE_ID" "$TEAM" "iCloud.com.example.other" "$CONTAINER"

IDENTITY="Developer ID Application: Acme Corp ($TEAM)"

# run_case <sign_identity> <profile path or empty> <BUILD_FLAVOR or empty>
#          [WATCHTOWER_CLOUDKIT_ENV]
# Runs both snippets in a fresh fake bundle; prints their output, then the
# recorded codesign argv. Propagates the snippets' exit code.
run_case() {
    rm -rf "$WORK_DIR/stage" "$SIGNED_ENT"
    mkdir -p "$WORK_DIR/stage/Watchtower.app/Contents/MacOS"
    : > "$CODESIGN_LOG"
    local rc=0
    # shellcheck disable=SC2034 # read by the sourced snippets
    (
        PATH="$STUB_DIR:$PATH"
        PROJECT_ROOT="$WORK_DIR"
        APP_BUNDLE="$WORK_DIR/stage/Watchtower.app"
        ENTITLEMENTS="$BASE_ENT"
        ENTITLEMENTS_CLOUD="$CLOUD_ENT"
        SIGN_IDENTITY="$1"
        WATCHTOWER_PROVISION_PROFILE="$2"
        WATCHTOWER_CLOUDKIT_ENV="${4:-}"
        BUILD_FLAVOR="$3"
        FLAVOR="$3"
        ADHOC_REASON="test reason"
        TIMESTAMP_FLAG=""
        set -euo pipefail
        # shellcheck disable=SC1090
        . "$CHECK_SNIPPET"
        # shellcheck disable=SC1090
        . "$SIGN_SNIPPET"
    ) 2>&1 || rc=$?
    echo "--- codesign calls"
    cat "$CODESIGN_LOG"
    return "$rc"
}

# bundle_sign_line — the codesign call that signs the .app itself.
bundle_sign_line() {
    grep -E 'Watchtower\.app$' "$CODESIGN_LOG" || true
}

# signed_key <key> — a key of the entitlements the bundle was signed with.
signed_key() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$SIGNED_ENT" 2>/dev/null || echo "<missing>"
}

EMBEDDED="$WORK_DIR/stage/Watchtower.app/Contents/embedded.provisionprofile"

# --- 1. Real identity + matching profile → cloud + merged ids, embedded -----
OUT=$(run_case "$IDENTITY" "$PROFILE" "")
LINE=$(bundle_sign_line)
check "matching profile signs the bundle with the real identity" "$LINE" "--sign $IDENTITY"
check "matching profile signs with a cloud entitlements copy" "$LINE" "Watchtower-cloud.entitlements"
check "signed entitlements: application-identifier from the profile" \
    "$(signed_key com.apple.application-identifier)" "$TEAM.$BUNDLE_ID"
check "signed entitlements: team-identifier from the profile" \
    "$(signed_key com.apple.developer.team-identifier)" "$TEAM"
check "signed entitlements: the container" \
    "$(signed_key com.apple.developer.icloud-container-identifiers:0)" "$CONTAINER"
check "signed entitlements: Production environment" \
    "$(signed_key com.apple.developer.icloud-container-environment)" "Production"
check "signed entitlements: aps-environment production" \
    "$(signed_key com.apple.developer.aps-environment)" "production"
check "signed entitlements: base key kept" \
    "$(signed_key com.apple.security.device.audio-input)" "true"
if [ -f "$EMBEDDED" ] && cmp -s "$PROFILE" "$EMBEDDED"; then
    echo "ok: profile embedded as Contents/embedded.provisionprofile"
else
    note_fail "profile embedded as Contents/embedded.provisionprofile"
fi
check "matching profile is reported" "$OUT" "Provisioning profile OK: $TEAM.$BUNDLE_ID"
check_absent "the Go binary never gets the cloud entitlements" \
    "$(grep 'MacOS/watchtower$' "$CODESIGN_LOG" || true)" "entitlements"

# A relative profile path resolves against the project root.
run_case "$IDENTITY" "acme.provisionprofile" "" > /dev/null
check "relative profile path resolves against the project root" \
    "$(signed_key com.apple.developer.team-identifier)" "$TEAM"

# --- 2. Ad-hoc path → base entitlements only --------------------------------
OUT=$(run_case "-" "$PROFILE" "")
check "ad-hoc bundle signs with the base entitlements" "$(bundle_sign_line)" "--entitlements $BASE_ENT"
check_absent "ad-hoc never uses the cloud entitlements" "$(cat "$CODESIGN_LOG")" "Watchtower-cloud"
check "ad-hoc notes the profile is ignored" "$OUT" "provisioning profile ignored: ad-hoc signing"
if [ -e "$EMBEDDED" ]; then
    note_fail "ad-hoc embeds no provisioning profile"
else
    echo "ok: ad-hoc embeds no provisioning profile"
fi

OUT=$(run_case "-" "" "")
check_absent "ad-hoc without a profile prints no profile note" "$OUT" "profile ignored"

# --- 3. Real identity without a profile → base + warning --------------------
OUT=$(run_case "$IDENTITY" "" "")
check "no profile signs the bundle with the base entitlements" "$(bundle_sign_line)" "--entitlements $BASE_ENT"
check_absent "no profile never uses the cloud entitlements" "$(cat "$CODESIGN_LOG")" "Watchtower-cloud"
check "no profile warns the hub is disabled" "$OUT" "hub disabled: no provisioning profile"
if [ -e "$EMBEDDED" ]; then
    note_fail "no profile embeds nothing"
else
    echo "ok: no profile embeds nothing"
fi

# --- 4. Bad profiles → hard error, nothing signed ---------------------------
# expect_fail <label> <profile path> <error substring> [WATCHTOWER_CLOUDKIT_ENV]
expect_fail() {
    local rc=0 out
    out=$(run_case "$IDENTITY" "$2" "" "${4:-}") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ok: $1 fails the build"
    else
        note_fail "$1 fails the build (got rc=0)"
    fi
    check "$1: error says why" "$out" "$3"
    check_absent "$1: nothing signed" "$(cat "$CODESIGN_LOG")" "codesign"
}

expect_fail "missing profile file" "$WORK_DIR/missing.provisionprofile" "not found"

printf 'BROKEN\n' > "$WORK_DIR/broken.provisionprofile"
expect_fail "undecodable profile" "$WORK_DIR/broken.provisionprofile" "could not be decoded"

make_profile "$WORK_DIR/wrong-app.provisionprofile" "$TEAM.com.aiwatchtowers.watchtower" "$TEAM" "$CONTAINER"
expect_fail "profile for the wrong App ID" "$WORK_DIR/wrong-app.provisionprofile" "<TEAM>.$BUNDLE_ID"

make_profile "$WORK_DIR/wrong-team.provisionprofile" "OTHER00001.$BUNDLE_ID" "$TEAM" "$CONTAINER"
expect_fail "profile whose App ID prefix is not its team" "$WORK_DIR/wrong-team.provisionprofile" "<TEAM>.$BUNDLE_ID"

make_profile "$WORK_DIR/no-container.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "iCloud.com.example.other"
expect_fail "profile without the container" "$WORK_DIR/no-container.provisionprofile" "does not grant the iCloud container $CONTAINER"

PROFILE_SERVICES="iCloudDocuments" make_profile "$WORK_DIR/no-cloudkit.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "$CONTAINER"
expect_fail "profile without CloudKit" "$WORK_DIR/no-cloudkit.provisionprofile" "does not grant CloudKit"

PROFILE_APS="none" make_profile "$WORK_DIR/no-aps.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "$CONTAINER"
expect_fail "profile without aps-environment" "$WORK_DIR/no-aps.provisionprofile" "has no aps-environment"

PROFILE_ENVS="none" make_profile "$WORK_DIR/no-env.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "$CONTAINER"
expect_fail "profile without a CloudKit environment" "$WORK_DIR/no-env.provisionprofile" "does not grant the CloudKit environment Production"

PROFILE_ENVS="Development" PROFILE_APS="development" \
    make_profile "$WORK_DIR/dev-only.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "$CONTAINER"
expect_fail "default (Production) build with a Development-only profile" \
    "$WORK_DIR/dev-only.provisionprofile" "does not grant the CloudKit environment Production"

# --- 4b. WATCHTOWER_CLOUDKIT_ENV ---------------------------------------------
PROFILE_SERVICES="*" PROFILE_ENVS="Development Production" PROFILE_APS="development" \
    make_profile "$WORK_DIR/dev.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "$CONTAINER"
OUT=$(run_case "$IDENTITY" "$WORK_DIR/dev.provisionprofile" "" "Development")
check "Development: signed entitlements carry the Development environment" \
    "$(signed_key com.apple.developer.icloud-container-environment)" "Development"
check "Development: signed entitlements carry aps-environment development" \
    "$(signed_key com.apple.developer.aps-environment)" "development"
check "Development: the container is kept" \
    "$(signed_key com.apple.developer.icloud-container-identifiers:0)" "$CONTAINER"
check "Development: the profile is reported with the environment" "$OUT" "(CloudKit Development)"
check "Development: the repo's entitlements stay Production" \
    "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$CLOUD_ENT")" "Production"

expect_fail "Development with a Developer ID (Production-only) profile" \
    "$PROFILE" "does not grant the CloudKit environment Development" "Development"

PROFILE_ENVS="Development Production" PROFILE_APS="production" \
    make_profile "$WORK_DIR/dev-env-prod-aps.provisionprofile" "$TEAM.$BUNDLE_ID" "$TEAM" "$CONTAINER"
expect_fail "Development with a production aps-environment" \
    "$WORK_DIR/dev-env-prod-aps.provisionprofile" "needs 'development'" "Development"

expect_fail "an unknown WATCHTOWER_CLOUDKIT_ENV" "$PROFILE" "is neither Production nor Development" "Staging"

OUT=$(run_case "-" "" "" "Staging" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "ok: an unknown WATCHTOWER_CLOUDKIT_ENV fails even without a profile"
else
    note_fail "an unknown WATCHTOWER_CLOUDKIT_ENV fails even without a profile (got rc=0)"
fi

# --- 5. BUILD_FLAVOR=corp → the same container ------------------------------
if grep -qE '\$\{?(BUILD_)?FLAVOR' "$CHECK_SNIPPET" "$SIGN_SNIPPET"; then
    note_fail "the signing blocks have no flavor logic"
else
    echo "ok: the signing blocks have no flavor logic"
fi
run_case "$IDENTITY" "$PROFILE" "corp" > /dev/null
check "BUILD_FLAVOR=corp signs with the same container" \
    "$(signed_key com.apple.developer.icloud-container-identifiers:0)" "$CONTAINER"

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
check "cloud entitlements: Production container environment" \
    "$(pb 'com.apple.developer.icloud-container-environment' "$CLOUD_ENT")" "Production"
check "cloud entitlements: aps-environment production" \
    "$(pb 'com.apple.developer.aps-environment' "$CLOUD_ENT")" "production"
check "cloud entitlements: no hard-coded application-identifier" \
    "$(pb 'com.apple.application-identifier' "$CLOUD_ENT")" "<missing>"
check "cloud entitlements: no hard-coded team-identifier" \
    "$(pb 'com.apple.developer.team-identifier' "$CLOUD_ENT")" "<missing>"
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
