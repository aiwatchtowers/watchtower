#!/bin/bash
set -euo pipefail

# pwd -P: the live-process guard compares against the resolved paths ps prints.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# BEGIN profile-selection (extracted verbatim by scripts/tests/test-build-app-profile.sh)
# Source the build profile if present (OAuth credentials, BUILD_FLAVOR etc.).
# ENV_FILE selects an alternative profile (e.g. ENV_FILE=.env.b2 make app);
# relative paths resolve against the project root. An explicitly requested
# profile that is missing is a hard error — silently building with default
# credentials would produce an artifact indistinguishable from the right one.
# The default/explicit split keys off the RESOLVED path, so an explicit
# ENV_FILE=.env behaves exactly like not setting ENV_FILE at all (intended).
# A non-default profile must set BUILD_FLAVOR: a flavorless profile build
# would wear the default artifact name while carrying non-default credentials
# — the same mislabeled-artifact failure, from the other direction.
# Flavors deliberately share the bundle id, install path, and Application
# Support directory — same product, different baked credentials. Co-installing
# two flavors on one machine is out of scope.
ENV_FILE="${ENV_FILE:-.env}"
case "$ENV_FILE" in
    /*) : ;;
    *) ENV_FILE="$PROJECT_ROOT/$ENV_FILE" ;;
esac
if [ -f "$ENV_FILE" ]; then
    set -a
    . "$ENV_FILE"
    set +a
elif [ "$ENV_FILE" != "$PROJECT_ROOT/.env" ]; then
    echo "ERROR: build profile '$ENV_FILE' not found" >&2
    exit 1
fi
FLAVOR="${BUILD_FLAVOR:-}"
if [ "$ENV_FILE" != "$PROJECT_ROOT/.env" ] && [ -z "$FLAVOR" ]; then
    echo "ERROR: build profile '$ENV_FILE' must set BUILD_FLAVOR — without it the artifact would be indistinguishable from the default build" >&2
    exit 1
fi
if [ -n "$FLAVOR" ] && ! printf '%s' "$FLAVOR" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    echo "ERROR: BUILD_FLAVOR '$FLAVOR' must match [A-Za-z0-9._-]+ — it lands in ldflags and artifact file names" >&2
    exit 1
fi
FLAVOR_SUFFIX="${FLAVOR:+-$FLAVOR}"
# END profile-selection
DESKTOP_DIR="$PROJECT_ROOT/WatchtowerDesktop"
# Everything is built into STAGE_DIR, a sibling of build/, and promoted to
# BUILD_DIR by scripts/app-swap.sh only at the very end — so the owner can keep
# running the app from build/Watchtower.app through the whole build. Nothing in
# this script writes to BUILD_DIR directly (pinned by test-app-swap.sh).
BUILD_DIR="$PROJECT_ROOT/build"
STAGE_DIR="$PROJECT_ROOT/build.next"
APP_NAME="Watchtower"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
ENTITLEMENTS="$SCRIPT_DIR/Watchtower.entitlements"
# Mobile hub (iCloud/CloudKit + push): restricted entitlements, used only on
# the real-identity branch with an embedded provisioning profile (app-codesign).
ENTITLEMENTS_CLOUD="$SCRIPT_DIR/Watchtower-cloud.entitlements"
# CFBundleIdentifier of the app (Info.plist below). Every flavor shares it, so
# one provisioning profile serves them all.
BUNDLE_ID="com.watchtower.desktop"

# BEGIN provision-profile-check (extracted verbatim by scripts/tests/test-build-app-cloud.sh)
# WATCHTOWER_PROVISION_PROFILE (optional; usually set in the build profile)
# names a Developer ID provisioning profile for App ID $BUNDLE_ID that grants
# the mobile hub's iCloud container. It is checked here, before the long Swift
# build, so a wrong profile fails fast. A hand-signed app with restricted
# entitlements must also carry com.apple.application-identifier and
# com.apple.developer.team-identifier matching the profile (Xcode adds them;
# codesign does not), so they are copied out of the profile into a temporary
# copy of the cloud entitlements — the team id is never written in the repo.
# Sets PROVISION_PROFILE and SIGNED_CLOUD_ENTITLEMENTS (both empty without a
# profile); app-codesign embeds and uses them on the real-identity branch.
HUB_CONTAINER="iCloud.com.aiwatchtowers.watchtower"
PROVISION_PROFILE=""
SIGNED_CLOUD_ENTITLEMENTS=""
if [ -n "${WATCHTOWER_PROVISION_PROFILE:-}" ]; then
    case "$WATCHTOWER_PROVISION_PROFILE" in
        /*) PROVISION_PROFILE="$WATCHTOWER_PROVISION_PROFILE" ;;
        *) PROVISION_PROFILE="$PROJECT_ROOT/$WATCHTOWER_PROVISION_PROFILE" ;;
    esac
    if [ ! -f "$PROVISION_PROFILE" ]; then
        echo "ERROR: WATCHTOWER_PROVISION_PROFILE '$PROVISION_PROFILE' not found — refusing to build without the mobile hub it asked for" >&2
        exit 1
    fi
    PROFILE_WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$PROFILE_WORK_DIR"' EXIT
    PROFILE_PLIST="$PROFILE_WORK_DIR/profile.plist"
    if ! security cms -D -i "$PROVISION_PROFILE" > "$PROFILE_PLIST" 2> "$PROFILE_WORK_DIR/cms.err"; then
        echo "ERROR: WATCHTOWER_PROVISION_PROFILE '$PROVISION_PROFILE' could not be decoded (security cms -D): $(cat "$PROFILE_WORK_DIR/cms.err")" >&2
        exit 1
    fi
    PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)
    PROFILE_TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST" 2>/dev/null || true)
    if [ -z "$PROFILE_TEAM_ID" ] || [ "$PROFILE_APP_ID" != "$PROFILE_TEAM_ID.$BUNDLE_ID" ]; then
        echo "ERROR: WATCHTOWER_PROVISION_PROFILE '$PROVISION_PROFILE' is for App ID '${PROFILE_APP_ID:-<none>}' (team '${PROFILE_TEAM_ID:-<none>}'); the app is <TEAM>.$BUNDLE_ID — make a Developer ID profile for that App ID" >&2
        exit 1
    fi
    if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers' "$PROFILE_PLIST" 2>/dev/null \
        | sed -E 's/^[[:space:]]+//' | grep -qxF "$HUB_CONTAINER"; then
        echo "ERROR: WATCHTOWER_PROVISION_PROFILE '$PROVISION_PROFILE' does not grant the iCloud container $HUB_CONTAINER" >&2
        exit 1
    fi
    SIGNED_CLOUD_ENTITLEMENTS="$PROFILE_WORK_DIR/Watchtower-cloud.entitlements"
    cp "$ENTITLEMENTS_CLOUD" "$SIGNED_CLOUD_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$SIGNED_CLOUD_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM_ID" "$SIGNED_CLOUD_ENTITLEMENTS"
    echo "==> Provisioning profile OK: $PROFILE_APP_ID with $HUB_CONTAINER"
fi
# END provision-profile-check

# Parse flags
DEV_MODE=false
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=true ;;
        *) VERSION="$arg" ;;
    esac
done
VERSION="${VERSION:-0.2.0}"

# NOTARIZE_PROFILE is only read on the release path (dev mode exits before
# notarization), so one unconditional default suffices.
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"

# Without create-dmg the DMG silently degrades to a bare hdiutil image (no
# window layout, opens like a plain folder), so surface that up front.
if ! $DEV_MODE && ! command -v create-dmg &>/dev/null; then
    echo "WARNING: create-dmg not found — DMG will be a bare hdiutil image without installer window layout." >&2
    echo "         Install it with: brew install create-dmg" >&2
fi
FLAVOR_NOTE="${FLAVOR:+ [flavor: $FLAVOR]}"
if $DEV_MODE; then
    echo "==> Building Watchtower v$VERSION (arm64)$FLAVOR_NOTE [DEV MODE — no DMG/ZIP/notarization]"
else
    echo "==> Building Watchtower v$VERSION (arm64)$FLAVOR_NOTE"
fi
echo ""

# shellcheck source=lib/app-guard.sh
. "$SCRIPT_DIR/lib/app-guard.sh"

# BEGIN finish-staged-build (extracted verbatim by scripts/tests/test-app-swap.sh)
# finish_staged_build — marks the staging dir complete and hands it to
# app-swap.sh. While anything runs from build/ the swap is DEFERRED (exit 3):
# the result stays in STAGE_DIR and the build ends with a banner telling the
# owner to quit the app and run `make app-swap`. A dev build then exits 0; a
# release build exits 3 too (finish_exit), so a release flow that picks up
# build/*.dmg / *.zip after `make app` can never ship the previous build's
# artifacts. Any other swap failure fails the build. Sets OUT_DIR (where
# the artifacts ended up), APP_BUNDLE and SWAP_DEFERRED.
# app-swap.sh runs as a child process, not a sourced function, so its own
# set -e stays in force despite the `||` here. WAIT is cleared for it: an
# exported WAIT=1 must not turn the end of a build into a 10-minute wait.
finish_staged_build() {
    touch "$STAGE_DIR/$STAGED_BUILD_MARKER"
    cd "$PROJECT_ROOT"
    local swap_rc=0
    WAIT='' "$SCRIPT_DIR/app-swap.sh" || swap_rc=$?
    case "$swap_rc" in
        0) OUT_DIR="$BUILD_DIR"; SWAP_DEFERRED=false ;;
        3) OUT_DIR="$STAGE_DIR"; SWAP_DEFERRED=true ;;
        *)
            echo "ERROR: the build finished but promoting it to $BUILD_DIR failed (app-swap exit $swap_rc); the finished build is in $STAGE_DIR" >&2
            exit "$swap_rc"
            ;;
    esac
    APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
}

# finish_exit — the build's last step: prints the deferral banner when the
# swap was deferred and exits (3 for a deferred release build, else 0).
finish_exit() {
    if $SWAP_DEFERRED; then
        echo ""
        echo "!!! BUILD OK, NOT YET IN build/: Watchtower is running from $BUILD_DIR."
        if ! $DEV_MODE; then
            echo "!!! Release artifacts (DMG/ZIP/checksums) are in $STAGE_DIR — they become build/ after 'make app-swap'."
        fi
        echo "!!! Quit Watchtower (⌘Q), then run: make app-swap   (or: WAIT=1 make app-swap)"
        if ! $DEV_MODE; then
            exit 3
        fi
    fi
    exit 0
}
# END finish-staged-build

# Clean the previous staging dir only; build/ stays untouched until the swap.
# Someone may have launched a deferred staged build straight from build.next/:
# the same live-process rule applies to the directory we are about to delete.
RUNNING_FROM_STAGE=$(running_from "$STAGE_DIR") || {
    echo "ERROR: could not read the process list (ps failed) — refusing to delete $STAGE_DIR" >&2
    exit 1
}
if [ -n "$RUNNING_FROM_STAGE" ]; then
    echo "ERROR: a Watchtower process is running from $STAGE_DIR — quit it before rebuilding:" >&2
    printf '%s\n' "$RUNNING_FROM_STAGE" >&2
    exit 1
fi
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# 1. Build Go CLI
echo "==> Building Go CLI..."
cd "$PROJECT_ROOT"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OAUTH_ID="${WATCHTOWER_OAUTH_CLIENT_ID:-}"
OAUTH_SECRET="${WATCHTOWER_OAUTH_CLIENT_SECRET:-}"
GOOGLE_ID="${WATCHTOWER_GOOGLE_CLIENT_ID:-}"
GOOGLE_SECRET="${WATCHTOWER_GOOGLE_CLIENT_SECRET:-}"
JIRA_ID="${WATCHTOWER_JIRA_CLIENT_ID:-}"
JIRA_SECRET="${WATCHTOWER_JIRA_CLIENT_SECRET:-}"
MS_ID="${WATCHTOWER_MICROSOFT_CLIENT_ID:-}"
# -tags codegrammars: the code index's full grammar set (an untagged build
# carries only Go, Swift and Python).
GOARCH=arm64 CGO_ENABLED=1 go build -tags codegrammars \
    -ldflags="-s -w -X watchtower/cmd.Version=${VERSION} -X watchtower/cmd.Commit=${COMMIT} -X watchtower/cmd.BuildDate=${BUILD_DATE} -X watchtower/cmd.BuildFlavor=${FLAVOR} -X watchtower/internal/auth.DefaultClientID=${OAUTH_ID} -X watchtower/internal/auth.DefaultClientSecret=${OAUTH_SECRET} -X watchtower/internal/calendar.DefaultGoogleClientID=${GOOGLE_ID} -X watchtower/internal/calendar.DefaultGoogleClientSecret=${GOOGLE_SECRET} -X watchtower/internal/jira.DefaultJiraClientID=${JIRA_ID} -X watchtower/internal/jira.DefaultJiraClientSecret=${JIRA_SECRET} -X watchtower/internal/imap.DefaultMicrosoftClientID=${MS_ID}" \
    -o "$STAGE_DIR/watchtower" .
echo "    Go CLI built ($(du -h "$STAGE_DIR/watchtower" | cut -f1))"

# 2. Build Swift desktop app
# POC (code viewer): the Monaco build is fetched, not committed.
"$SCRIPT_DIR/fetch-monaco.sh"
echo "==> Building Desktop app..."
cd "$DESKTOP_DIR"
swift build -c release --arch arm64 2>&1

BINARY=$(swift build -c release --arch arm64 --show-bin-path)/WatchtowerDesktop

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Desktop binary not found at $BINARY"
    exit 1
fi

# The watchtower-ocr helper (Vision OCR for attachment scans, run by the Go
# CLI): its own small executable target with no GRDB/ML dependencies.
swift build -c release --arch arm64 --product watchtower-ocr 2>&1
OCR_HELPER=$(swift build -c release --arch arm64 --show-bin-path)/watchtower-ocr
if [ ! -f "$OCR_HELPER" ]; then
    echo "ERROR: OCR helper not found at $OCR_HELPER"
    exit 1
fi

echo "==> Creating app bundle..."

# Create .app structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy desktop binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/WatchtowerDesktop"

# Copy SPM resource bundles into Contents/Resources/ (standard macOS .app location)
# AppBundle.resources searches here via Bundle.main.resourceURL
RESOURCE_BUNDLE_DIR=$(swift build -c release --arch arm64 --show-bin-path)
for bundle in "$RESOURCE_BUNDLE_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        echo "    Copied resource bundle: $(basename "$bundle")"
    fi
done

# Build MLX's Metal kernel library and ship it as the SwiftPM resource bundle
# MLX searches at runtime (Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib
# — what an Xcode build would have produced). SwiftPM CLI builds cannot compile
# Metal shaders (mlx-swift README), so without this any MLX inference (Qwen3
# engine) aborts the app with "Failed to load the default metallib". A bare
# metallib in Contents/MacOS is NOT an option: codesign --strict treats it as an
# unsigned subcomponent and verification fails.
echo "==> Building MLX metallib..."
# BUILD_DIR here is scoped to the child script only (speech-swift's script reads it); the outer $BUILD_DIR is untouched.
BUILD_DIR="$DESKTOP_DIR/.build" bash "$DESKTOP_DIR/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" release
MLX_BUNDLE="$APP_BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle"
mkdir -p "$MLX_BUNDLE"
cp "$DESKTOP_DIR/.build/release/mlx.metallib" "$MLX_BUNDLE/default.metallib"
cat > "$MLX_BUNDLE/Info.plist" << 'MLXPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
</dict>
</plist>
MLXPLIST
echo "    Bundled default.metallib ($(du -h "$MLX_BUNDLE/default.metallib" | cut -f1))"

# Copy Go CLI into bundle, and the OCR helper next to it (the CLI looks for
# watchtower-ocr beside its own executable; CLIBinaryStore copies both).
cp "$STAGE_DIR/watchtower" "$APP_BUNDLE/Contents/MacOS/watchtower"
cp "$OCR_HELPER" "$APP_BUNDLE/Contents/MacOS/watchtower-ocr"

# The licence notices of the third-party code compiled into the CLI (the
# tree-sitter runtime and the code index's grammars): MIT, Apache-2.0 and
# MPL-2.0 need them to reach whoever receives the binary. Guarded by
# scripts/tests/test-build-app-notices.sh.
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WatchtowerDesktop</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Watchtower</string>
    <key>CFBundleDisplayName</key>
    <string>Watchtower</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Watchtower uses the microphone to record your side of meetings and to take voice dictation, transcribed locally.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Watchtower records meeting audio (other participants) to transcribe it locally. Audio never leaves this Mac.</string>
    <key>LSUIElement</key>
    <false/>
    <!-- Layered with SingleInstanceGuard.swift: keep LaunchServices from launching a second instance of this bundle.
         Per-app-bundle, not per-bundle-id — it does not cover a second on-disk copy sharing the identifier. -->
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Watchtower OAuth Callback</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>watchtower-auth</string>
            </array>
        </dict>
    </array>
    <key>INIntentsSupported</key>
    <array/>
    <key>NSUserActivityTypes</key>
    <array/>
    <key>NSCoreSpotlightContinuation</key>
    <false/>
    <key>CSSupportsSearchableItems</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Copy icon if exists
if [ -f "$DESKTOP_DIR/Resources/AppIcon.icns" ]; then
    cp "$DESKTOP_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist"
fi

# Stamp the flavor into the bundle so the app itself knows which build it is.
# UpdateService reads this key to keep flavored builds off the public release
# feed (their updates are distributed out-of-band). Absent on default builds —
# the default Info.plist stays byte-identical to the pre-flavor layout.
if [ -n "$FLAVOR" ]; then
    /usr/libexec/PlistBuddy -c "Add :WTBuildFlavor string $FLAVOR" "$APP_BUNDLE/Contents/Info.plist"
    # Gated update channel keys (flavored builds only; dev never updates —
    # UpdateService also enforces that, this just avoids shipping dead keys).
    # All three or none: a partial set would be a build that can locate the
    # feed but not authenticate, or vice versa. UpdateService fails closed on
    # a partial set anyway; erroring here catches the profile typo at build
    # time instead of shipping a silently non-updating artifact.
    _upd_set=0
    [ -n "${WATCHTOWER_UPDATE_FEED_URL:-}" ] && _upd_set=$((_upd_set+1))
    [ -n "${WATCHTOWER_UPDATE_CLIENT_ID:-}" ] && _upd_set=$((_upd_set+1))
    [ -n "${WATCHTOWER_UPDATE_CLIENT_SECRET:-}" ] && _upd_set=$((_upd_set+1))
    if [ "$FLAVOR" != "dev" ] && [ "$_upd_set" -eq 3 ]; then
        /usr/libexec/PlistBuddy -c "Add :WTUpdateFeedURL string $WATCHTOWER_UPDATE_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :WTUpdateClientID string $WATCHTOWER_UPDATE_CLIENT_ID" "$APP_BUNDLE/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :WTUpdateClientSecret string $WATCHTOWER_UPDATE_CLIENT_SECRET" "$APP_BUNDLE/Contents/Info.plist"
    elif [ "$FLAVOR" != "dev" ] && [ "$_upd_set" -ne 0 ]; then
        echo "ERROR: partial update-channel config — set all three WATCHTOWER_UPDATE_* vars or none" >&2
        exit 1
    fi
fi

# Code sign — one path for dev and release.
# TCC pins permission grants (mic, system audio) to the app's code signature. An
# ad-hoc signature has no designated requirement, so the grant keys off the
# bundle's cdhash — which changes every build (the Go binary embeds
# BuildDate/Commit via ldflags). New cdhash → "different app" → grant lost.
# A stable identity keeps grants across rebuilds, so prefer one:
#   1. explicit $CODESIGN_IDENTITY (on release builds a set-but-unusable
#      identity is a hard error — never silently substituted),
#   2. else a single auto-detected "Developer ID Application" identity,
#   3. else ad-hoc (grants will NOT survive rebuilds) with a cause-accurate warning.
# BEGIN signing-identity-selection (extracted verbatim by scripts/tests/test-build-app-signing.sh)
SIGN_IDENTITY="-"
ADHOC_REASON=""
# Dev builds skip the trusted timestamp (--timestamp=none): Developer ID
# signing requests a network timestamp by default, which would hard-fail an
# offline `make app-dev`. Identity and designated requirement are unchanged,
# so TCC grant stability is unaffected. Release builds keep the secure
# timestamp (required for notarization).
TIMESTAMP_FLAG=""
if $DEV_MODE; then
    TIMESTAMP_FLAG="--timestamp=none"
fi
# One `security` invocation serves both the explicit check and auto-detect.
# Capture stdout+stderr and the exit code so a failed lookup (locked/broken
# keychain) is distinguishable from "no certificate installed".
FIND_IDENTITY_RC=0
FIND_IDENTITY_OUTPUT=$(security find-identity -v -p codesigning 2>&1) || FIND_IDENTITY_RC=$?

if [ "$FIND_IDENTITY_RC" -ne 0 ]; then
    if [ -n "${CODESIGN_IDENTITY:-}" ] && ! $DEV_MODE; then
        echo "ERROR: CODESIGN_IDENTITY '$CODESIGN_IDENTITY' is set but the keychain lookup failed (security find-identity exit $FIND_IDENTITY_RC):"
        echo "$FIND_IDENTITY_OUTPUT"
        exit 1
    fi
    ADHOC_REASON="keychain identity lookup failed (security find-identity exit $FIND_IDENTITY_RC — locked or broken keychain?): $FIND_IDENTITY_OUTPUT"
elif [ -n "${CODESIGN_IDENTITY:-}" ] && printf '%s\n' "$FIND_IDENTITY_OUTPUT" | grep -qF "$CODESIGN_IDENTITY"; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
else
    # Reaching this branch with CODESIGN_IDENTITY set means the lookup
    # succeeded but the explicit identity was NOT in it (re-tested above).
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        if ! $DEV_MODE; then
            echo "ERROR: CODESIGN_IDENTITY '$CODESIGN_IDENTITY' not found in the keychain — refusing to substitute a different certificate on a release build."
            exit 1
        fi
        echo "WARNING: CODESIGN_IDENTITY '$CODESIGN_IDENTITY' not found in keychain — trying auto-detect."
    fi
    # sort -u: the same certificate can appear in several keychains (login +
    # System), producing identical output lines — those must count as ONE
    # identity, not trip the exactly-one gate into ad-hoc.
    DETECTED_IDENTITY=$(printf '%s\n' "$FIND_IDENTITY_OUTPUT" \
        | grep "Developer ID Application" \
        | sed -E 's/^.*"(.+)"[[:space:]]*$/\1/' \
        | sort -u || true)
    IDENTITY_COUNT=0
    if [ -n "$DETECTED_IDENTITY" ]; then
        IDENTITY_COUNT=$(printf '%s\n' "$DETECTED_IDENTITY" | wc -l | tr -d ' ')
    fi
    if [ "$IDENTITY_COUNT" -eq 1 ]; then
        SIGN_IDENTITY="$DETECTED_IDENTITY"
        echo "==> Auto-detected signing identity: $SIGN_IDENTITY"
    elif [ "$IDENTITY_COUNT" -eq 0 ]; then
        ADHOC_REASON="no \"Developer ID Application\" identity found in the keychain. Install a Developer ID Application certificate or set CODESIGN_IDENTITY for stable grants."
    else
        ADHOC_REASON="$IDENTITY_COUNT distinct \"Developer ID Application\" identities found in the keychain — ambiguous. Set CODESIGN_IDENTITY to choose one."
    fi
fi
# END signing-identity-selection

# BEGIN app-codesign (extracted verbatim by scripts/tests/test-build-app-cloud.sh)
# The mobile hub needs the iCloud container, CloudKit and push entitlements.
# They are restricted: they take effect only with a real identity and an
# embedded Developer ID provisioning profile that grants them, checked and
# merged by provision-profile-check (PROVISION_PROFILE →
# Contents/embedded.provisionprofile, SIGNED_CLOUD_ENTITLEMENTS). Without a
# profile the bundle signs with the base entitlements and the hub reports
# "Needs a signed build". Ad-hoc never gets them: amfid kills an ad-hoc app
# that carries restricted entitlements. The block has no flavor logic on
# purpose — every flavor uses the same container.
if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> Code signing with: $SIGN_IDENTITY"
    BUNDLE_ENTITLEMENTS="$ENTITLEMENTS"
    if [ -n "$PROVISION_PROFILE" ]; then
        cp "$PROVISION_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
        BUNDLE_ENTITLEMENTS="$SIGNED_CLOUD_ENTITLEMENTS"
        echo "    Embedded provisioning profile: $PROVISION_PROFILE (iCloud/CloudKit + push entitlements)"
    else
        echo "    WARNING: mobile hub disabled: no provisioning profile (set WATCHTOWER_PROVISION_PROFILE) — signing with the base entitlements."
    fi
    codesign --force --options runtime ${TIMESTAMP_FLAG:+"$TIMESTAMP_FLAG"} --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/watchtower"
    codesign --force --options runtime ${TIMESTAMP_FLAG:+"$TIMESTAMP_FLAG"} --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/watchtower-ocr"
    codesign --force --options runtime ${TIMESTAMP_FLAG:+"$TIMESTAMP_FLAG"} --entitlements "$BUNDLE_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "==> Ad-hoc code signing..."
    echo "    WARNING: $ADHOC_REASON"
    if [ -n "$PROVISION_PROFILE" ]; then
        echo "    NOTE: provisioning profile ignored: ad-hoc signing (the mobile hub needs a real identity)."
    fi
    echo "    Signing ad-hoc: TCC permission grants (microphone, system audio) will"
    echo "    NOT survive rebuilds — the grant is pinned to the bundle's cdhash,"
    echo "    which changes every build."
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/watchtower"
    # The OCR helper needs no entitlement at all: never give it the app's.
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/watchtower-ocr"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi
# END app-codesign

# In dev mode, skip DMG/ZIP/notarization — just output the .app
if $DEV_MODE; then
    finish_staged_build
    echo ""
    echo "==> Done! (dev mode)"
    echo "    App: $APP_BUNDLE"
    echo ""
    if ! $SWAP_DEFERRED; then
        echo "    To run: open \"$APP_BUNDLE\"   (or 'make app-install' to run an installed copy)"
    fi
    finish_exit
fi

# Create DMG
echo "==> Creating DMG..."
DMG_NAME="Watchtower${FLAVOR_SUFFIX}-arm64.dmg"
DMG_PATH="$STAGE_DIR/$DMG_NAME"
DMG_STAGING="$STAGE_DIR/dmg-staging"

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
# No manual Applications symlink here: create-dmg's --app-drop-link creates it
# inside the image itself and errors ("File exists") on a pre-existing one.

if command -v create-dmg &>/dev/null; then
    # Pretty DMG with window layout (brew install create-dmg)
    create-dmg \
        --volname "Watchtower" \
        --volicon "$APP_BUNDLE/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 185 \
        --icon "Applications" 450 185 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$DMG_STAGING"
    dmg_rc=$?
    if [ "$dmg_rc" -ne 0 ] && [ "$dmg_rc" -ne 2 ]; then
        echo "ERROR: create-dmg failed with exit code $dmg_rc"
        exit 1
    fi
else
    # Fallback: hdiutil (always available on macOS) — needs the Applications
    # symlink staged manually since hdiutil won't create one.
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create \
        -volname "Watchtower" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

# Create ZIP (used by auto-update + install script)
echo "==> Creating ZIP..."
ZIP_NAME="Watchtower-${VERSION}${FLAVOR_SUFFIX}-arm64.zip"
cd "$STAGE_DIR"
ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_NAME"
ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)

# Notarize if credentials are configured
if [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARIZE_PROFILE" ]; then
    echo "==> Notarizing ZIP..."
    xcrun notarytool submit "$ZIP_NAME" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "==> Stapling app bundle..."
    xcrun stapler staple "$APP_BUNDLE"

    # Re-create DMG with stapled app
    echo "==> Re-creating DMG with stapled app..."
    rm -f "$DMG_PATH"
    DMG_STAGING="$STAGE_DIR/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    # No manual Applications symlink — see the first DMG block.

    if command -v create-dmg &>/dev/null; then
        create-dmg \
            --volname "Watchtower" \
            --volicon "$APP_BUNDLE/Contents/Resources/AppIcon.icns" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "$APP_NAME.app" 150 185 \
            --icon "Applications" 450 185 \
            --hide-extension "$APP_NAME.app" \
            --app-drop-link 450 185 \
            --no-internet-enable \
            "$DMG_PATH" \
            "$DMG_STAGING" || {
                [ $? -eq 2 ] || exit 1
            }
    else
        ln -s /Applications "$DMG_STAGING/Applications"
        hdiutil create \
            -volname "Watchtower" \
            -srcfolder "$DMG_STAGING" \
            -ov \
            -format UDZO \
            "$DMG_PATH"
    fi
    rm -rf "$DMG_STAGING"

    echo "==> Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait

    echo "==> Stapling DMG..."
    xcrun stapler staple "$DMG_PATH"

    # Re-create ZIP with stapled app
    echo "==> Re-creating ZIP with stapled app..."
    rm -f "$ZIP_NAME"
    ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_NAME"

    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
else
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "==> Skipping notarization (ad-hoc signing)"
    else
        echo "==> Skipping notarization (NOTARIZE_PROFILE not set)"
    fi
fi

# Generate checksums
echo "==> Generating checksums..."
# Flavored builds get a flavored manifest so artifacts moved out of build/
# stay self-describing; the default name is a contract with install.sh.
CHECKSUMS="$STAGE_DIR/checksums${FLAVOR_SUFFIX}.txt"
shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > "$CHECKSUMS"

finish_staged_build
echo ""
echo "==> Done!"
echo "    App:  $APP_BUNDLE"
echo "    DMG:  $OUT_DIR/$DMG_NAME ($DMG_SIZE)"
echo "    ZIP:  $OUT_DIR/$ZIP_NAME ($ZIP_SIZE)  ← auto-update"
echo "    SHA:  $OUT_DIR/$(basename "$CHECKSUMS")"
if [ -n "$NOTARIZE_PROFILE" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo "    Notarized & stapled ✓"
fi
echo ""
echo "    Contents:"
echo "      - WatchtowerDesktop (GUI app)"
echo "      - watchtower (CLI — bundled)"
echo ""
echo "    To install: open DMG → drag Watchtower to Applications"
finish_exit
