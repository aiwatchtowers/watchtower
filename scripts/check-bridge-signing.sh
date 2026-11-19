#!/bin/bash
# Checks the CloudKit bridge helper's signing inputs and result (Go hub plan phase 3, Task 10).
#
#   check-bridge-signing.sh --profile <profile>
#       The helper's Developer ID provisioning profile: decodable (security cms -D), for an App ID ending in
#       .com.watchtower.desktop.cloudbridge, granting the app's iCloud container, CloudKit, the CloudKit
#       environment and aps-environment the build asks for. build-app.sh runs it before anything is built.
#
#   check-bridge-signing.sh <WatchtowerCloudBridge.app> <signed entitlements>
#       The signed helper: its embedded.provisionprofile passes the profile check, its Info.plist
#       CFBundleIdentifier is the helper's bundle id, and the entitlements `codesign -d` reads from it equal
#       <signed entitlements> and are a subset of the profile's. build-app.sh runs it right after signing.
#
# Environment: HUB_CONTAINER (default iCloud.com.aiwatchtowers.watchtower), CLOUDKIT_ENV (Production or
# Development, default Production). Exit 0 = OK; any failure prints one "ERROR: …" line with its reason.
set -euo pipefail

BRIDGE_BUNDLE_ID="com.watchtower.desktop.cloudbridge"
HUB_CONTAINER="${HUB_CONTAINER:-iCloud.com.aiwatchtowers.watchtower}"
CLOUDKIT_ENV="${CLOUDKIT_ENV:-Production}"
case "$CLOUDKIT_ENV" in
    Production) APS_ENV="production" ;;
    Development) APS_ENV="development" ;;
    *) echo "ERROR: CloudKit environment '$CLOUDKIT_ENV' is neither Production nor Development" >&2; exit 1 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# check_profile <profile> — the profile checks; leaves the decoded plist at $WORK/profile.plist.
check_profile() {
    local profile="$1" plist="$WORK/profile.plist"
    [ -f "$profile" ] || fail "bridge provisioning profile '$profile' not found"
    security cms -D -i "$profile" > "$plist" 2> "$WORK/cms.err" \
        || fail "bridge provisioning profile '$profile' could not be decoded (security cms -D): $(cat "$WORK/cms.err")"
    local app_id
    app_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)
    case "$app_id" in
        *."$BRIDGE_BUNDLE_ID") ;;
        *) fail "bridge provisioning profile '$profile' is for App ID '${app_id:-<none>}'; the helper is <TEAM>.$BRIDGE_BUNDLE_ID — make a Developer ID profile for that App ID" ;;
    esac
    values() {
        /usr/libexec/PlistBuddy -c "Print :Entitlements:$1" "$plist" 2>/dev/null | sed -E 's/^[[:space:]]+//' || true
    }
    values com.apple.developer.icloud-container-identifiers | grep -qxF "$HUB_CONTAINER" \
        || fail "bridge provisioning profile '$profile' does not grant the iCloud container $HUB_CONTAINER"
    values com.apple.developer.icloud-services | grep -qxE 'CloudKit|\*' \
        || fail "bridge provisioning profile '$profile' does not grant CloudKit (com.apple.developer.icloud-services)"
    values com.apple.developer.icloud-container-environment | grep -qxF "$CLOUDKIT_ENV" \
        || fail "bridge provisioning profile '$profile' does not grant the CloudKit environment $CLOUDKIT_ENV"
    local aps
    aps=$(values com.apple.developer.aps-environment)
    [ -n "$aps" ] || fail "bridge provisioning profile '$profile' has no aps-environment — enable Push Notifications for the App ID $BRIDGE_BUNDLE_ID and download the profile again"
    [ "$aps" = "$APS_ENV" ] || fail "bridge provisioning profile '$profile' has aps-environment '$aps'; CloudKit $CLOUDKIT_ENV needs '$APS_ENV'"
}

if [ "${1:-}" = "--profile" ]; then
    [ $# -eq 2 ] || fail "usage: check-bridge-signing.sh --profile <profile>"
    check_profile "$2"
    exit 0
fi
[ $# -eq 2 ] || fail "usage: check-bridge-signing.sh <WatchtowerCloudBridge.app> <signed entitlements>"
APP="$1"
EXPECTED="$2"

check_profile "$APP/Contents/embedded.provisionprofile"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
[ "$bundle_id" = "$BRIDGE_BUNDLE_ID" ] \
    || fail "the helper's Info.plist CFBundleIdentifier is '${bundle_id:-<none>}', not $BRIDGE_BUNDLE_ID"

codesign -d --entitlements - --xml "$APP" > "$WORK/signed.plist" 2> "$WORK/codesign.err" \
    || fail "could not read the helper's signed entitlements: $(cat "$WORK/codesign.err")"
[ -s "$WORK/signed.plist" ] || fail "the signed helper carries no entitlements"

as_json() {
    plutil -convert json -o - "$1" | jq -S .
}
as_json "$WORK/signed.plist" > "$WORK/signed.json" || fail "the helper's signed entitlements are not a property list"
as_json "$EXPECTED" > "$WORK/expected.json" || fail "'$EXPECTED' is not a property list"
cmp -s "$WORK/signed.json" "$WORK/expected.json" \
    || fail "the helper's signed entitlements differ from $EXPECTED: $(diff "$WORK/expected.json" "$WORK/signed.json" | head -n 6 | tr '\n' ' ')"

/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/profile-ents.plist"
as_json "$WORK/profile-ents.plist" > "$WORK/profile.json"
# Every signed key must be granted: an equal value, an element of a granted array (or "*"), a granted prefix
# wildcard ("TEAM.*"), and for an array every element so.
not_granted=$(jq -r --slurpfile p "$WORK/profile.json" '
    ($p[0]) as $g
    | def ok($v; $pv):
        if $pv == null then false
        elif $pv == $v then true
        elif ($pv | type) == "array" then ($pv | index($v)) != null or ($pv | index("*")) != null
        elif ($pv | type) == "string" then $pv == "*" or (($pv | endswith("*")) and ($v | type) == "string" and ($v | startswith($pv[:-1])))
        else false end;
      to_entries[]
    | select(
        if (.value | type) == "array" then ([.value[] as $v | ok($v; $g[.key])] | all | not)
        else (ok(.value; $g[.key]) | not) end)
    | .key' "$WORK/signed.json")
[ -z "$not_granted" ] || fail "the helper is signed with entitlements its profile does not grant: $(echo "$not_granted" | tr '\n' ' ')"
echo "==> CloudKit bridge signing OK: $bundle_id with $HUB_CONTAINER (CloudKit $CLOUDKIT_ENV)"
