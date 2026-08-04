#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source .env if present (for OAuth credentials etc.)
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    . "$PROJECT_ROOT/.env"
    set +a
fi
DESKTOP_DIR="$PROJECT_ROOT/WatchtowerDesktop"
BUILD_DIR="$PROJECT_ROOT/build"
APP_NAME="Watchtower"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ENTITLEMENTS="$SCRIPT_DIR/Watchtower.entitlements"

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
if $DEV_MODE; then
    echo "==> Building Watchtower v$VERSION (arm64) [DEV MODE — no DMG/ZIP/notarization]"
else
    echo "==> Building Watchtower v$VERSION (arm64)"
fi
echo ""

# BEGIN live-process-guard (extracted verbatim by scripts/tests/test-build-app-guard.sh)
# Refuse to rebuild while anything executes from build/: rm -rf replaces the
# binary beneath the live process (app, bundled daemon, or standalone CLI),
# breaking its Security.framework/TLS and desyncing LaunchServices.
# ps snapshot is taken separately so set -e still aborts if ps itself fails
# (the guard must fail closed).
# awk matches the WHOLE LINE by literal prefix: `ps -axo command=` emits no
# leading whitespace, so the executable path always starts at position 1 and an
# argv that merely MENTIONS build/ in a later token can never match there. The
# match is index()/literal rather than a regex because paths carry regex
# metacharacters ('+' in worktree names); matching $0 rather than $1 also keeps
# a BUILD_DIR containing a space from being truncated at the field split.
# `awk -v` processes backslash escapes in p — irrelevant for macOS paths, which
# do not realistically contain backslashes.
# Accepted limitation: a process launched via a RELATIVE argv (./build/watchtower)
# is not matched, since ps reports argv[0] as typed. Every primary consumer (the
# app bundle, the make targets, the daemon spawn) launches from an absolute path.
PS_SNAPSHOT=$(ps -axo command=)
RUNNING_FROM_BUILD=$(printf '%s\n' "$PS_SNAPSHOT" | awk -v p="$BUILD_DIR/" 'index($0, p) == 1')
if [ -n "$RUNNING_FROM_BUILD" ]; then
    echo "ERROR: a Watchtower process (app or daemon) is still running from $BUILD_DIR — quit it before rebuilding:" >&2
    printf '%s\n' "$RUNNING_FROM_BUILD" >&2
    exit 1
fi
# END live-process-guard

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

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
GOARCH=arm64 CGO_ENABLED=1 go build \
    -ldflags="-s -w -X watchtower/cmd.Version=${VERSION} -X watchtower/cmd.Commit=${COMMIT} -X watchtower/cmd.BuildDate=${BUILD_DATE} -X watchtower/internal/auth.DefaultClientID=${OAUTH_ID} -X watchtower/internal/auth.DefaultClientSecret=${OAUTH_SECRET} -X watchtower/internal/calendar.DefaultGoogleClientID=${GOOGLE_ID} -X watchtower/internal/calendar.DefaultGoogleClientSecret=${GOOGLE_SECRET} -X watchtower/internal/jira.DefaultJiraClientID=${JIRA_ID} -X watchtower/internal/jira.DefaultJiraClientSecret=${JIRA_SECRET} -X watchtower/internal/imap.DefaultMicrosoftClientID=${MS_ID}" \
    -o "$BUILD_DIR/watchtower" .
echo "    Go CLI built ($(du -h "$BUILD_DIR/watchtower" | cut -f1))"

# 2. Build Swift desktop app
echo "==> Building Desktop app..."
cd "$DESKTOP_DIR"
swift build -c release --arch arm64 2>&1

BINARY=$(swift build -c release --arch arm64 --show-bin-path)/WatchtowerDesktop

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Desktop binary not found at $BINARY"
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

# Copy Go CLI into bundle
cp "$BUILD_DIR/watchtower" "$APP_BUNDLE/Contents/MacOS/watchtower"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WatchtowerDesktop</string>
    <key>CFBundleIdentifier</key>
    <string>com.watchtower.desktop</string>
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
    <string>Watchtower records your side of meetings to transcribe them locally.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Watchtower records meeting audio (other participants) to transcribe it locally. Audio never leaves this Mac.</string>
    <key>LSUIElement</key>
    <false/>
    <!-- Layered with SingleInstanceGuard.swift: keep LaunchServices from launching a second instance of this bundle id. -->
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

if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> Code signing with: $SIGN_IDENTITY"
    codesign --force --options runtime ${TIMESTAMP_FLAG:+"$TIMESTAMP_FLAG"} --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/MacOS/watchtower"
    codesign --force --options runtime ${TIMESTAMP_FLAG:+"$TIMESTAMP_FLAG"} --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "==> Ad-hoc code signing..."
    echo "    WARNING: $ADHOC_REASON"
    echo "    Signing ad-hoc: TCC permission grants (microphone, system audio) will"
    echo "    NOT survive rebuilds — the grant is pinned to the bundle's cdhash,"
    echo "    which changes every build."
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/watchtower"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi

# In dev mode, skip DMG/ZIP/notarization — just output the .app
if $DEV_MODE; then
    echo ""
    echo "==> Done! (dev mode)"
    echo "    App: $APP_BUNDLE"
    echo ""
    echo "    To run: open $APP_BUNDLE"
    exit 0
fi

# Create DMG
echo "==> Creating DMG..."
DMG_NAME="Watchtower-arm64.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

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
    # Fallback: hdiutil (always available on macOS)
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
ZIP_NAME="Watchtower-${VERSION}-arm64.zip"
cd "$BUILD_DIR"
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
    DMG_STAGING="$BUILD_DIR/dmg-staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_BUNDLE" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

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
CHECKSUMS="$BUILD_DIR/checksums.txt"
shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > "$CHECKSUMS"

echo ""
echo "==> Done!"
echo "    App:  $APP_BUNDLE"
echo "    DMG:  $DMG_PATH ($DMG_SIZE)"
echo "    ZIP:  $BUILD_DIR/$ZIP_NAME ($ZIP_SIZE)  ← auto-update"
echo "    SHA:  $CHECKSUMS"
if [ -n "$NOTARIZE_PROFILE" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo "    Notarized & stapled ✓"
fi
echo ""
echo "    Contents:"
echo "      - WatchtowerDesktop (GUI app)"
echo "      - watchtower (CLI — bundled)"
echo ""
echo "    To install: open DMG → drag Watchtower to Applications"
