#!/bin/bash
#
# Watchtower Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/vadimtrunov/watchtower/main/scripts/install.sh | bash
#
set -euo pipefail

REPO="vadimtrunov/watchtower"
APP_NAME="Watchtower"
INSTALL_DIR="/Applications"
CLI_LINK="/usr/local/bin/watchtower"
# Apple Developer Team ID that every official release is signed with. This is
# the installer's trust anchor: unlike the in-app updater, a fresh install has
# no already-trusted copy of the app to compare against, so the expected Team
# ID has to be pinned here rather than read from the bundle being installed
# (reading it from the download would pin nothing — an attacker's bundle would
# simply carry the attacker's Team ID and validate against itself).
TEAM_ID="7WFLZDVUV3"

# --- Helpers ---

info()  { printf "\033[1;34m==>\033[0m \033[1m%s\033[0m\n" "$1"; }
ok()    { printf "\033[1;32m  ✓\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m  !\033[0m %s\n" "$1"; }
fail()  { printf "\033[1;31mError:\033[0m %s\n" "$1" >&2; exit 1; }

cleanup() {
    [ -n "${TMPDIR_INSTALL:-}" ] && rm -rf "$TMPDIR_INSTALL"
}
trap cleanup EXIT

# --- Pre-flight checks ---

info "Watchtower Installer"
echo ""

# macOS only
[ "$(uname -s)" = "Darwin" ] || fail "Watchtower is only supported on macOS."

# arm64 only for now
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    fail "Watchtower currently supports Apple Silicon (arm64) only. Detected: $ARCH"
fi

# Need curl
command -v curl >/dev/null 2>&1 || fail "curl is required but not found."

# --- Fetch latest release ---

info "Finding latest release..."

RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest") \
    || fail "Could not fetch release info from GitHub. Check your internet connection."

VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
[ -n "$VERSION" ] || fail "Could not determine latest version."

# Strip leading 'v' for asset name
VERSION_NUM="${VERSION#v}"
CHECKSUMS_NAME="checksums.txt"

ok "Latest version: $VERSION"

# Resolve the download URL of a release asset by exact file name. Matching on
# the URL's last path component (rather than a substring grep over the JSON)
# keeps an asset whose name merely contains the wanted one from being picked.
asset_url() {
    echo "$RELEASE_JSON" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | sed 's/.*"browser_download_url": *"//;s/"$//' \
        | awk -v want="$1" '{ n = $0; sub(/.*\//, "", n); if (n == want) { print; exit } }'
}

# The release ZIP has shipped both with and without the leading "v" in its
# version component (the git tag is passed verbatim to build-app.sh), so try
# both spellings.
ASSET_NAME=""
ASSET_URL=""
for candidate in "${APP_NAME}-${VERSION}-arm64.zip" "${APP_NAME}-${VERSION_NUM}-arm64.zip"; do
    ASSET_URL=$(asset_url "$candidate" || true)
    if [ -n "$ASSET_URL" ]; then
        ASSET_NAME="$candidate"
        break
    fi
done
[ -n "$ASSET_URL" ] || fail "Could not find ${APP_NAME}-${VERSION_NUM}-arm64.zip in release $VERSION."

# Checksums are mandatory — see the fail-closed verification below.
CHECKSUMS_URL=$(asset_url "$CHECKSUMS_NAME" || true)
[ -n "$CHECKSUMS_URL" ] || fail "Release $VERSION publishes no $CHECKSUMS_NAME, so the download cannot be verified. Refusing to install. Please report this at https://github.com/${REPO}/issues"

# --- Download ---

TMPDIR_INSTALL=$(mktemp -d)

info "Downloading $ASSET_NAME..."
curl -fSL --progress-bar -o "$TMPDIR_INSTALL/$ASSET_NAME" "$ASSET_URL" \
    || fail "Download failed."
ok "Downloaded $(du -h "$TMPDIR_INSTALL/$ASSET_NAME" | cut -f1 | xargs)"

# --- Verify checksum ---
#
# Fail-closed: a checksum that cannot be fetched, parsed or matched aborts the
# install. Skipping verification would defeat its purpose, since the cases
# where it cannot be performed are exactly the cases worth worrying about.

info "Verifying checksum..."
curl -fsSL -o "$TMPDIR_INSTALL/$CHECKSUMS_NAME" "$CHECKSUMS_URL" \
    || fail "Could not download $CHECKSUMS_NAME from $CHECKSUMS_URL. Refusing to install an unverified download — check your connection and try again."

# shasum lines are "<sha256>  <filename>", with a "*" before the name in
# binary mode. Compare the name exactly so a line for another asset cannot
# supply the hash for this one.
EXPECTED=$(awk -v want="$ASSET_NAME" '{ f = $2; sub(/^\*/, "", f); if (f == want) { print $1; exit } }' "$TMPDIR_INSTALL/$CHECKSUMS_NAME")
[ -n "$EXPECTED" ] \
    || fail "$CHECKSUMS_NAME has no entry for $ASSET_NAME, so the download cannot be verified. Refusing to install. Please report this at https://github.com/${REPO}/issues"
printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-fA-F]{64}$' \
    || fail "$CHECKSUMS_NAME entry for $ASSET_NAME is not a SHA-256 digest (got: $EXPECTED). Refusing to install."

ACTUAL=$(shasum -a 256 "$TMPDIR_INSTALL/$ASSET_NAME" | awk '{print $1}')
[ "$EXPECTED" = "$ACTUAL" ] \
    || fail "Checksum mismatch for $ASSET_NAME (expected $EXPECTED, got $ACTUAL). The download is corrupt or has been tampered with. Refusing to install."
ok "Checksum verified (SHA-256)"

# --- Install ---

info "Installing to $INSTALL_DIR..."

# Unzip
ditto -x -k "$TMPDIR_INSTALL/$ASSET_NAME" "$TMPDIR_INSTALL/extracted" \
    || fail "Failed to unzip $ASSET_NAME."

# Find .app in extracted contents
APP_PATH=$(find "$TMPDIR_INSTALL/extracted" -name "*.app" -maxdepth 2 -type d | head -1)
[ -n "$APP_PATH" ] || fail "Could not find .app bundle in archive."

# --- Verify code signature ---
#
# This, not the checksum, is what defends against a substituted release asset:
# whoever can replace the ZIP can replace checksums.txt alongside it, but
# cannot produce a signature that chains to Apple for our Team ID. The
# requirement mirrors the in-app updater (UpdateService.swift). Ad-hoc signed
# (`codesign -s -`) and unsigned bundles carry no Team ID and are refused.
#
# Verified in the temp directory, before the installed copy is touched, so a
# rejected download never leaves the user without a working app. codesign is
# called by absolute path because this script goes on to run sudo.
info "Verifying code signature..."
/usr/bin/codesign --verify --deep --strict \
    -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
    "$APP_PATH" \
    || fail "Code signature verification failed: this build is not signed by Watchtower's Apple Developer ID (Team $TEAM_ID). Refusing to install. Do not run this download; please report it at https://github.com/${REPO}/issues"
ok "Signature verified (Developer ID, Team $TEAM_ID)"

# Remove old version if present
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    warn "Removing previous installation..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

# Move to Applications (may need sudo)
if cp -R "$APP_PATH" "$INSTALL_DIR/" 2>/dev/null; then
    ok "Installed $APP_NAME.app"
else
    info "Need administrator access to install to $INSTALL_DIR..."
    sudo cp -R "$APP_PATH" "$INSTALL_DIR/" \
        || fail "Could not install to $INSTALL_DIR."
    ok "Installed $APP_NAME.app"
fi

# The quarantine attribute is deliberately NOT stripped here: curl does not
# set it (it only records com.apple.provenance), and releases are notarized
# and stapled, so Gatekeeper admits the bundle even when the flag is present.
# Stripping it would therefore change nothing on this path except to suppress
# Gatekeeper's evaluation of a build that failed to notarize — which is a
# check worth keeping. Do not re-add it.

# --- CLI symlink ---

CLI_PATH="$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/watchtower"
if [ -f "$CLI_PATH" ]; then
    info "Setting up CLI..."
    # Ensure /usr/local/bin exists
    if [ ! -d "$(dirname "$CLI_LINK")" ]; then
        sudo mkdir -p "$(dirname "$CLI_LINK")"
    fi

    if ln -sf "$CLI_PATH" "$CLI_LINK" 2>/dev/null; then
        ok "CLI available: watchtower"
    else
        sudo ln -sf "$CLI_PATH" "$CLI_LINK" 2>/dev/null \
            && ok "CLI available: watchtower" \
            || warn "Could not create symlink at $CLI_LINK. Add $CLI_PATH to your PATH manually."
    fi
fi

# --- Done ---

echo ""
info "Watchtower $VERSION installed successfully!"
echo ""
echo "  Open the app:   open -a Watchtower"
echo "  CLI:            watchtower --help"
echo "  Login:          watchtower login"
echo ""
