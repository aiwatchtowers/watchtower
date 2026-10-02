#!/bin/bash
# Installs build/Watchtower.app into INSTALL_DIR (default /Applications), so the
# owner runs the installed copy and build/ stays free for the next `make app`.
#
# Usage: make app-install                          (→ /Applications)
#        make app-install INSTALL_DIR=~/Applications
#
# If the app is running from the install location, asks the owner to quit it
# (⌘Q) and waits (WAIT_TIMEOUT seconds, default 600) — never quits or kills it —
# then relaunches it after the copy. The bundle is copied next to the
# destination first and renamed into place, so a failed copy never leaves a
# half bundle behind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
STAGE_DIR="$PROJECT_ROOT/build.next"
APP_NAME="Watchtower.app"
SRC="$BUILD_DIR/$APP_NAME"
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
# A quoted or make-passed '~/...' arrives unexpanded; the patterns below match
# the literal tilde on purpose.
# shellcheck disable=SC2088
case "$INSTALL_DIR" in
    "~") INSTALL_DIR="$HOME" ;;
    "~/"*) INSTALL_DIR="$HOME/${INSTALL_DIR#"~/"}" ;;
esac
DEST="$INSTALL_DIR/$APP_NAME"
TMP_DEST="$INSTALL_DIR/.$APP_NAME.installing"
OLD_DEST="$INSTALL_DIR/.$APP_NAME.old"

# shellcheck source=lib/app-guard.sh
. "$SCRIPT_DIR/lib/app-guard.sh"

if [ -f "$STAGE_DIR/$STAGED_BUILD_MARKER" ]; then
    echo "ERROR: a newer build is staged in $STAGE_DIR but not swapped into $BUILD_DIR yet — run 'make app-swap' first" >&2
    exit 1
fi
if [ ! -d "$SRC" ]; then
    echo "ERROR: $SRC not found — run 'make app' first" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$TMP_DEST"
trap 'rm -rf "$TMP_DEST"' EXIT

# Copy first (the slow part) while the installed app may still run; ditto
# preserves the code signature, extended attributes and symlinks.
echo "==> Copying $SRC → $TMP_DEST..."
ditto "$SRC" "$TMP_DEST"

WAS_RUNNING=false
RUNNING=$(running_from "$DEST") || {
    echo "ERROR: could not read the process list (ps failed) — refusing to replace $DEST" >&2
    exit 1
}
if [ -n "$RUNNING" ]; then
    WAS_RUNNING=true
    wait_until_free "$DEST"
fi

rm -rf "$OLD_DEST"
if [ -e "$DEST" ]; then
    mv "$DEST" "$OLD_DEST"
fi
if ! mv "$TMP_DEST" "$DEST"; then
    [ -e "$OLD_DEST" ] && mv "$OLD_DEST" "$DEST"
    echo "ERROR: could not move the new bundle into $DEST — the previous install (if any) was moved back" >&2
    exit 1
fi
rm -rf "$OLD_DEST"
echo "==> Installed $DEST"

# Both bundles share one bundle id; point LaunchServices at the installed one so
# `open -b`, URL schemes (watchtower-auth://) and Spotlight resolve to it.
# Best-effort: a stale registration is an annoyance, not a failed install.
if ! "$LSREGISTER" -u "$SRC"; then
    echo "WARNING: lsregister -u failed — LaunchServices may still resolve the bundle id (open -b, watchtower-auth://) to $SRC" >&2
fi
if ! "$LSREGISTER" -f "$DEST"; then
    echo "WARNING: lsregister -f failed — LaunchServices may not know $DEST yet" >&2
fi

if $WAS_RUNNING; then
    echo "==> Relaunching $DEST"
    open "$DEST"
fi
