#!/usr/bin/env bash
# Builds and signs the Stage 2 keychain gate probe bundles (board #603,
# docs/superpowers/plans/2026-10-21-db-encryption-stage1.md § Stage 2 gate).
# Throwaway spike, never merged.
#
#   probe/make-bundles.sh --sign developer-id [--notarize] [--out DIR] [--version V] [--install-dir DIR | --no-install]
#   probe/make-bundles.sh --sign adhoc [--out DIR] [--version V] [--install-dir DIR]
#
# Output (outside the repo; default $TMPDIR/watchtower-probe-build):
#   DIR/Probe.app                                      CFBundleIdentifier com.watchtower.desktop
#   DIR/Probe.app/Contents/Helpers/Watchtower CLI.app  com.watchtower.desktop.cli
# Both run the same probe binary.
#
# developer-id: CODESIGN_IDENTITY (or the single "Developer ID Application"
# identity in the keychain) and WATCHTOWER_PROVISION_PROFILE, read from the
# environment or the build profile ENV_FILE (default: the main checkout's
# .env, as scripts/build-app.sh sources it). The entitlements
# (application-identifier, team-identifier, keychain-access-groups) are merged
# from the profile into a temporary file at sign time; the team id is never
# written in the repo. The helper bundle is installed into
# ~/Library/Application Support/WatchtowerProbe/bin/ with a `watchtower`
# symlink unless --no-install. The real Watchtower directory is never touched.
#
# adhoc: `codesign --sign -`, no profile, no entitlements (G5). Not installed
# unless --install-dir is given, so it never replaces the signed helper.
#
# --notarize (developer-id only): notarytool with the keychain profile in
# NOTARIZE_PROFILE (the one scripts/build-app.sh uses), then staple.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_ID_SUFFIX="com.watchtower.desktop"
HELPER_ID="com.watchtower.desktop.cli"

SIGN=""
NOTARIZE=false
OUT="${TMPDIR:-/tmp}"
OUT="${OUT%/}/watchtower-probe-build"
VERSION="0.1.0"
INSTALL_DIR=""
INSTALL_SET=false
NO_INSTALL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --sign) SIGN="${2:-}"; shift 2 ;;
        --notarize) NOTARIZE=true; shift ;;
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --install-dir) INSTALL_DIR="${2:?--install-dir needs a directory}"; INSTALL_SET=true; shift 2 ;;
        --no-install) NO_INSTALL=true; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

case "$SIGN" in
    developer-id|adhoc) ;;
    *) echo "ERROR: --sign developer-id|adhoc is required" >&2; exit 2 ;;
esac
if $NOTARIZE && [ "$SIGN" != developer-id ]; then
    echo "ERROR: --notarize needs --sign developer-id" >&2
    exit 2
fi
if [ "$SIGN" = developer-id ] && ! $INSTALL_SET && ! $NO_INSTALL; then
    INSTALL_DIR="$HOME/Library/Application Support/WatchtowerProbe/bin"
fi
if $NO_INSTALL; then
    INSTALL_DIR=""
fi
if [ -n "$INSTALL_DIR" ]; then
    case "$INSTALL_DIR/" in
        "$HOME/Library/Application Support/Watchtower/"*)
            echo "ERROR: refusing to install into the real Watchtower directory" >&2
            exit 2 ;;
    esac
fi
case "$OUT" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "ERROR: --out must be outside the repository" >&2
        exit 2 ;;
esac

# Build profile, as scripts/build-app.sh sources it (the env wins only if the
# profile does not set the variable; same as build-app.sh's `set -a; .`).
if [ "$SIGN" = developer-id ]; then
    if [ -z "${ENV_FILE:-}" ]; then
        COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        if [ -n "$COMMON_DIR" ]; then
            ENV_FILE="$(dirname "$COMMON_DIR")/.env"
        fi
    fi
    if [ -n "${ENV_FILE:-}" ] && [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        set +a
        echo "==> Build profile sourced"
    fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- signing inputs -----------------------------------------------------------
SIGN_IDENTITY="-"
PROFILE=""
ENTITLEMENTS=""
if [ "$SIGN" = developer-id ]; then
    IDENTITIES="$(security find-identity -v -p codesigning)"
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        if ! printf '%s\n' "$IDENTITIES" | grep -qF "$CODESIGN_IDENTITY"; then
            echo "ERROR: CODESIGN_IDENTITY is set but not found in the keychain (is the Mac unlocked?)" >&2
            exit 1
        fi
        SIGN_IDENTITY="$CODESIGN_IDENTITY"
    else
        COUNT="$(printf '%s\n' "$IDENTITIES" | grep '"Developer ID Application' | awk '{print $2}' | sort -u | grep -c . || true)"
        if [ "$COUNT" != 1 ]; then
            echo "ERROR: set CODESIGN_IDENTITY ($COUNT Developer ID Application identities found)" >&2
            exit 1
        fi
        SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | grep '"Developer ID Application' | head -1 | awk '{print $2}')"
    fi

    if [ -z "${WATCHTOWER_PROVISION_PROFILE:-}" ]; then
        echo "ERROR: WATCHTOWER_PROVISION_PROFILE is not set (env or build profile)" >&2
        exit 1
    fi
    case "$WATCHTOWER_PROVISION_PROFILE" in
        /*) PROFILE="$WATCHTOWER_PROVISION_PROFILE" ;;
        *) PROFILE="$(dirname "${ENV_FILE:-$REPO_ROOT/.env}")/$WATCHTOWER_PROVISION_PROFILE" ;;
    esac
    if [ ! -f "$PROFILE" ]; then
        echo "ERROR: WATCHTOWER_PROVISION_PROFILE does not name an existing file" >&2
        exit 1
    fi
    PROFILE_PLIST="$WORK/profile.plist"
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
    PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    if [ -z "$TEAM" ] || [ "$PROFILE_APP_ID" != "$TEAM.$APP_ID_SUFFIX" ]; then
        echo "ERROR: the profile is not for App ID <TEAM>.$APP_ID_SUFFIX" >&2
        exit 1
    fi
    GROUP="$TEAM.$APP_ID_SUFFIX"
    PROFILE_GROUPS="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' "$PROFILE_PLIST" 2>/dev/null | sed -E 's/^[[:space:]]+//' || true)"
    if ! printf '%s\n' "$PROFILE_GROUPS" | grep -qxF -e "$GROUP" -e "$TEAM.*"; then
        echo "WARNING: the profile's keychain-access-groups does not list <TEAM>.$APP_ID_SUFFIX or <TEAM>.* — amfid may reject the signature" >&2
    fi
    ENTITLEMENTS="$WORK/probe.entitlements"
    cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
PLIST
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $GROUP" "$ENTITLEMENTS"
    echo "==> Profile OK: <TEAM>.$APP_ID_SUFFIX, entitlements merged"
fi

# --- build --------------------------------------------------------------------
echo "==> Building probe $VERSION"
mkdir -p "$OUT"
BIN="$WORK/probe"
(cd "$REPO_ROOT" && CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
    go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$BIN" ./probe)

APP="$OUT/Probe.app"
HELPER="$APP/Contents/Helpers/Watchtower CLI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$HELPER/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/probe"
cp "$BIN" "$HELPER/Contents/MacOS/watchtower"

write_plist() { # <file> <bundle id> <executable> <name>
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$2</string>
    <key>CFBundleExecutable</key><string>$3</string>
    <key>CFBundleName</key><string>$4</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}
write_plist "$APP/Contents/Info.plist" "$APP_ID_SUFFIX" probe Probe
write_plist "$HELPER/Contents/Info.plist" "$HELPER_ID" watchtower "Watchtower CLI"

# --- sign (inner bundle first, no --deep) ------------------------------------
if [ "$SIGN" = developer-id ]; then
    cp "$PROFILE" "$HELPER/Contents/embedded.provisionprofile"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    for b in "$HELPER" "$APP"; do
        codesign --force --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$b"
    done
else
    for b in "$HELPER" "$APP"; do
        codesign --force --sign - "$b"
    done
fi
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# --- notarize -----------------------------------------------------------------
if $NOTARIZE; then
    if [ -z "${NOTARIZE_PROFILE:-}" ]; then
        echo "ERROR: NOTARIZE_PROFILE is not set (env or build profile)" >&2
        exit 1
    fi
    ZIP="$WORK/Probe.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Notarizing"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait | tee "$WORK/notary.log"
    if ! grep -q 'status: Accepted' "$WORK/notary.log"; then
        echo "ERROR: notarization not accepted (xcrun notarytool log <id> --keychain-profile \"\$NOTARIZE_PROFILE\")" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    xcrun stapler staple "$HELPER" || echo "    NOTE: the helper could not be stapled on its own (the online ticket check still applies)"
fi

# --- install the helper copy --------------------------------------------------
if [ -n "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/Watchtower CLI.app.new"
    ditto "$HELPER" "$INSTALL_DIR/Watchtower CLI.app.new"
    rm -rf "$INSTALL_DIR/Watchtower CLI.app"
    mv "$INSTALL_DIR/Watchtower CLI.app.new" "$INSTALL_DIR/Watchtower CLI.app"
    ln -sfn "Watchtower CLI.app/Contents/MacOS/watchtower" "$INSTALL_DIR/watchtower"
    echo "==> Installed helper: $INSTALL_DIR/watchtower"
fi

echo "==> Done: $APP (version $VERSION, sign $SIGN$($NOTARIZE && echo ', notarized'))"
echo "    codesign facts: codesign -dv --verbose=4 \"$APP\" ; codesign -dv --verbose=4 \"$HELPER\""
