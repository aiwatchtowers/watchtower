#!/bin/bash
# Tests for the CloudKit bridge helper in scripts/build-app.sh (Go hub plan phase 3, Task 10): the
# bridge-profile-check, bridge-bundle and bridge-codesign blocks and scripts/check-bridge-signing.sh.
#
# A dry run: the blocks are extracted verbatim (BEGIN/END markers) and run against fixture profiles (plain
# plists a stubbed `security cms -D` hands back), a stubbed `codesign` that records the entitlements it signs
# with and reads them back for `codesign -d`, and no-op `otool`/`install_name_tool` — no keychain, no real
# signature, no Swift build.
#
# Covers:
#   - a matching profile → the helper sits at Contents/Helpers/WatchtowerCloudBridge.app with its
#     executable, Info.plist (com.watchtower.desktop.cloudbridge, LSUIElement, this version) and
#     embedded.provisionprofile; it is signed with the helper's entitlements plus the profile's application
#     and team ids, and check-bridge-signing.sh passes
#   - WATCHTOWER_BRIDGE_PROFILE unset → the remedy line, before anything else
#   - a profile without aps-environment, one for another bundle id, one without the container or CloudKit,
#     a missing file and an undecodable one → each fails with its reason
#   - the signed entitlements differing from the merged copy, or exceeding the profile, or a wrong
#     CFBundleIdentifier → check-bridge-signing.sh fails
#   - ad-hoc → signed without entitlements, with the warning
#   - the helper's entitlements file carries the container, CloudKit, Production and push, nothing else
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "skip: bridge-signing tests need macOS (PlistBuddy, plutil)"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/.."
REPO="$SCRIPTS/.."
BUILD_APP="$SCRIPTS/build-app.sh"
CHECK="$SCRIPTS/check-bridge-signing.sh"
BRIDGE_ENT="$REPO/WatchtowerDesktop/Resources/WatchtowerCloudBridge/WatchtowerCloudBridge.entitlements"
BRIDGE_PLIST="$REPO/WatchtowerDesktop/Resources/WatchtowerCloudBridge/Info.plist"
CONTAINER="iCloud.com.aiwatchtowers.watchtower"
BRIDGE_ID="com.watchtower.desktop.cloudbridge"
TEAM="ACME000001"

FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}
check() {
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *) note_fail "$1"; printf '  wanted substring: %s\n  got:\n%s\n' "$3" "$2" ;;
    esac
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

for block in bridge-profile-check bridge-bundle bridge-codesign; do
    sed -n "/# BEGIN $block/,/# END $block/p" "$BUILD_APP" > "$WORK_DIR/$block.sh"
    if [ ! -s "$WORK_DIR/$block.sh" ]; then
        echo "FAIL: block $block not found in build-app.sh — markers moved?"
        exit 1
    fi
done
if grep -q 'if \[ -n "${BRIDGE_APP:-}" \]; then sign_bridge; fi' "$BUILD_APP" \
    && [ "$(grep -c 'sign_bridge; fi' "$BUILD_APP")" -eq 2 ]; then
    echo "ok: app-codesign signs the helper on both branches"
else
    note_fail "app-codesign signs the helper on both branches"
fi

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/security" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "cms -D -i" ] || { echo "unexpected security call: $*" >&2; exit 2; }
[ -f "$4" ] || { echo "security: no such file" >&2; exit 1; }
if grep -q BROKEN "$4"; then echo "security: SecCMSDecoder failed" >&2; exit 1; fi
cat "$4"
EOF
# codesign: a signature records its --entitlements file in <bundle>/.signed (empty without one);
# `codesign -d --entitlements - --xml <bundle>` prints it back. SIGNED_OVERRIDE replaces what is recorded.
cat > "$STUB_DIR/codesign" <<'EOF'
#!/bin/bash
target="${!#}"
if [ "$1" = "-d" ]; then
    [ -s "$target/.signed" ] && cat "$target/.signed"
    exit 0
fi
ent="" prev=""
for a in "$@"; do
    [ "$prev" = "--entitlements" ] && ent="$a"
    prev="$a"
done
echo "codesign $*" >> "$CODESIGN_LOG"
if [ -n "${SIGNED_OVERRIDE:-}" ]; then cp "$SIGNED_OVERRIDE" "$target/.signed"
elif [ -n "$ent" ]; then cp "$ent" "$target/.signed"
else : > "$target/.signed"; fi
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/otool"
printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/install_name_tool"
chmod +x "$STUB_DIR"/*

# make_profile <path> <application-identifier> [aps|none] [container] [services]
make_profile() {
    local path="$1" app_id="$2" aps="${3:-production}" container="${4:-$CONTAINER}" services="${5:-CloudKit}"
    local aps_xml=""
    [ "$aps" != "none" ] && aps_xml="<key>com.apple.developer.aps-environment</key><string>$aps</string>"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Name</key><string>Acme bridge profile</string>
    <key>Entitlements</key>
    <dict>
        <key>com.apple.application-identifier</key><string>$app_id</string>
        <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
        <key>com.apple.developer.icloud-container-identifiers</key><array><string>$container</string></array>
        <key>com.apple.developer.icloud-services</key><array><string>$services</string></array>
        <key>com.apple.developer.icloud-container-environment</key><array><string>Production</string></array>
        $aps_xml
    </dict>
</dict>
</plist>
EOF
}

GOOD="$WORK_DIR/good.provisionprofile"
make_profile "$GOOD" "$TEAM.$BRIDGE_ID"

# run_case <sign identity> <WATCHTOWER_BRIDGE_PROFILE or "unset">
run_case() {
    rm -rf "$WORK_DIR/stage"
    mkdir -p "$WORK_DIR/stage/Watchtower.app/Contents/MacOS" "$WORK_DIR/bin"
    printf 'fake helper binary' > "$WORK_DIR/bin/WatchtowerCloudBridge"
    CODESIGN_LOG="$WORK_DIR/codesign.log"
    : > "$CODESIGN_LOG"
    local rc=0
    # shellcheck disable=SC2034 # read by the sourced blocks
    (
        export PATH="$STUB_DIR:$PATH" CODESIGN_LOG
        SCRIPT_DIR="$SCRIPTS"
        PROJECT_ROOT="$REPO"
        APP_BUNDLE="$WORK_DIR/stage/Watchtower.app"
        BRIDGE_BINARY="$WORK_DIR/bin/WatchtowerCloudBridge"
        VERSION="v1.2.3"
        HUB_CONTAINER="$CONTAINER"
        CLOUDKIT_ENV="Production"
        APS_ENV="production"
        SIGN_IDENTITY="$1"
        TIMESTAMP_FLAG=""
        if [ "$2" != "unset" ]; then WATCHTOWER_BRIDGE_PROFILE="$2"; else unset WATCHTOWER_BRIDGE_PROFILE; fi
        set -euo pipefail
        # shellcheck disable=SC1090,SC1091
        . "$WORK_DIR/bridge-profile-check.sh"
        . "$WORK_DIR/bridge-bundle.sh"
        . "$WORK_DIR/bridge-codesign.sh"
        sign_bridge
        cp "$SIGNED_BRIDGE_ENTITLEMENTS" "$WORK_DIR/merged.entitlements"
    ) > "$WORK_DIR/out.log" 2>&1 || rc=$?
    return $rc
}

HELPER="$WORK_DIR/stage/Watchtower.app/Contents/Helpers/WatchtowerCloudBridge.app"
IDENTITY="Developer ID Application: Acme Corp ($TEAM)"

# 1. A matching profile.
if run_case "$IDENTITY" "$GOOD"; then
    echo "ok: a matching profile builds and signs"
else
    note_fail "a matching profile builds and signs"
    cat "$WORK_DIR/out.log"
fi
out=$(cat "$WORK_DIR/out.log")
check "the signing check passed" "$out" "CloudKit bridge signing OK: $BRIDGE_ID"
[ -f "$HELPER/Contents/MacOS/WatchtowerCloudBridge" ] && echo "ok: helper executable embedded" || note_fail "helper executable embedded"
cmp -s "$GOOD" "$HELPER/Contents/embedded.provisionprofile" && echo "ok: profile embedded" || note_fail "profile embedded as Contents/embedded.provisionprofile"
info=$(plutil -p "$HELPER/Contents/Info.plist" 2>&1 || true)
check "Info.plist bundle id" "$info" "\"CFBundleIdentifier\" => \"$BRIDGE_ID\""
check "Info.plist LSUIElement" "$info" '"LSUIElement" => true'
check "Info.plist version" "$info" '"CFBundleShortVersionString" => "1.2.3"'
signed=$(plutil -p "$HELPER/.signed" 2>&1 || true)
check "signed with the profile's application id" "$signed" "\"com.apple.application-identifier\" => \"$TEAM.$BRIDGE_ID\""
check "signed with the push entitlement" "$signed" '"com.apple.developer.aps-environment" => "production"'
check "codesign hardened runtime" "$(cat "$WORK_DIR/codesign.log")" "--options runtime"

# 2. The remedy line when the profile is missing from .env.
if run_case "$IDENTITY" unset; then note_fail "no WATCHTOWER_BRIDGE_PROFILE stops the build"; fi
check "remedy line" "$(cat "$WORK_DIR/out.log")" "put its path in .env as WATCHTOWER_BRIDGE_PROFILE"
[ ! -d "$HELPER" ] && echo "ok: nothing assembled without a profile" || note_fail "nothing assembled without a profile"

# 3. Profiles that must fail, each with its reason.
make_profile "$WORK_DIR/noaps.provisionprofile" "$TEAM.$BRIDGE_ID" none
make_profile "$WORK_DIR/other.provisionprofile" "$TEAM.com.watchtower.desktop"
make_profile "$WORK_DIR/nocontainer.provisionprofile" "$TEAM.$BRIDGE_ID" production "iCloud.com.example.other"
make_profile "$WORK_DIR/nocloudkit.provisionprofile" "$TEAM.$BRIDGE_ID" production "$CONTAINER" CloudDocuments
printf 'BROKEN' > "$WORK_DIR/broken.provisionprofile"
for spec in \
    "noaps|has no aps-environment" \
    "other|is for App ID '$TEAM.com.watchtower.desktop'" \
    "nocontainer|does not grant the iCloud container" \
    "nocloudkit|does not grant CloudKit" \
    "broken|could not be decoded" \
    "missing|not found"; do
    name="${spec%%|*}" reason="${spec#*|}"
    if run_case "$IDENTITY" "$WORK_DIR/$name.provisionprofile"; then note_fail "$name profile fails"; fi
    check "$name profile fails with its reason" "$(cat "$WORK_DIR/out.log")" "$reason"
done

# 4. check-bridge-signing.sh on a signed helper that drifted.
run_case "$IDENTITY" "$GOOD" || note_fail "setup for the drift cases"
cp "$WORK_DIR/merged.entitlements" "$WORK_DIR/extra.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.device.audio-input bool true" "$WORK_DIR/extra.entitlements"
cp "$HELPER/.signed" "$WORK_DIR/good.signed"
cp "$WORK_DIR/extra.entitlements" "$HELPER/.signed"
out=$(PATH="$STUB_DIR:$PATH" "$CHECK" "$HELPER" "$WORK_DIR/merged.entitlements" 2>&1) && note_fail "drifted signature fails"
check "a signature that differs from the merged copy fails" "$out" "differ from"
out=$(PATH="$STUB_DIR:$PATH" "$CHECK" "$HELPER" "$WORK_DIR/extra.entitlements" 2>&1) && note_fail "an entitlement outside the profile fails"
check "an entitlement the profile does not grant fails" "$out" "com.apple.security.device.audio-input"
cp "$WORK_DIR/good.signed" "$HELPER/.signed"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.other" "$HELPER/Contents/Info.plist"
out=$(PATH="$STUB_DIR:$PATH" "$CHECK" "$HELPER" "$WORK_DIR/merged.entitlements" 2>&1) && note_fail "wrong bundle id fails"
check "a wrong CFBundleIdentifier fails" "$out" "CFBundleIdentifier is 'com.example.other'"

# 5. Ad-hoc.
if run_case "-" "$GOOD"; then echo "ok: ad-hoc build passes"; else note_fail "ad-hoc build passes"; cat "$WORK_DIR/out.log"; fi
check "ad-hoc warning" "$(cat "$WORK_DIR/out.log")" "signed ad-hoc without entitlements"
[ ! -s "$HELPER/.signed" ] && echo "ok: ad-hoc signs without entitlements" || note_fail "ad-hoc signs without entitlements"

# 6. The entitlements file and Info.plist in the repo.
ents=$(plutil -p "$BRIDGE_ENT")
check "entitlements: container" "$ents" "\"$CONTAINER\""
check "entitlements: CloudKit" "$ents" '"CloudKit"'
check "entitlements: Production" "$ents" '"com.apple.developer.icloud-container-environment" => "Production"'
check "entitlements: push" "$ents" '"com.apple.developer.aps-environment" => "production"'
keys=$(plutil -convert json -o - "$BRIDGE_ENT" | jq -r 'keys | length')
[ "$keys" = "4" ] && echo "ok: entitlements carry four keys only" || note_fail "entitlements carry four keys only (got $keys)"
check "repo Info.plist bundle id" "$(plutil -p "$BRIDGE_PLIST")" "\"CFBundleIdentifier\" => \"$BRIDGE_ID\""

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all bridge build checks passed"
