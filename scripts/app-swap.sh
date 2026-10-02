#!/bin/bash
# Promotes the finished staged build (build.next/) to build/.
#
# scripts/build-app.sh builds into build.next/ and runs this at the end, so the
# long build never touches build/ — the owner can keep running the app from
# build/Watchtower.app meanwhile. The swap itself only happens while nothing
# executes from build/ (see scripts/lib/app-guard.sh for why).
#
# Usage: make app-swap            (or scripts/app-swap.sh)
#        WAIT=1 make app-swap     wait for the owner to quit the app, then swap
#
# Exit codes: 0 swapped; 1 error (no or incomplete staged build, ps failure,
# WAIT timeout); 3 deferred — something runs from build/, staged build kept.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
STAGE_DIR="$PROJECT_ROOT/build.next"
OLD_DIR="$PROJECT_ROOT/build.old"

# shellcheck source=lib/app-guard.sh
. "$SCRIPT_DIR/lib/app-guard.sh"

if [ ! -d "$STAGE_DIR" ]; then
    echo "ERROR: no staged build at $STAGE_DIR — run 'make app' first" >&2
    exit 1
fi
if [ ! -f "$STAGE_DIR/$STAGED_BUILD_MARKER" ]; then
    echo "ERROR: the staged build at $STAGE_DIR is incomplete (did the last 'make app' fail?) — run 'make app' again" >&2
    exit 1
fi

if [ "${WAIT:-}" = "1" ]; then
    wait_until_free "$BUILD_DIR"
else
    RUNNING=$(running_from "$BUILD_DIR") || {
        echo "ERROR: could not read the process list (ps failed) — refusing to replace $BUILD_DIR" >&2
        exit 1
    }
    if [ -n "$RUNNING" ]; then
        {
            echo ""
            echo "!!! Swap deferred: Watchtower is running from $BUILD_DIR:"
            printf '%s\n' "$RUNNING"
            echo "!!! The finished build is waiting in $STAGE_DIR."
            echo "!!! Quit Watchtower (⌘Q), then run: make app-swap"
            echo "!!! (or 'WAIT=1 make app-swap' to wait for the quit and swap right after)"
            echo ""
        } >&2
        exit 3
    fi
fi

# Rename the old build aside, move the new one in, then delete the old one:
# build/ is missing only between two renames on the same filesystem.
rm -rf "$OLD_DIR"
if [ -e "$BUILD_DIR" ]; then
    mv "$BUILD_DIR" "$OLD_DIR"
fi
if ! mv "$STAGE_DIR" "$BUILD_DIR"; then
    [ -e "$OLD_DIR" ] && mv "$OLD_DIR" "$BUILD_DIR"
    echo "ERROR: could not move $STAGE_DIR into place — the previous build (if any) was moved back" >&2
    exit 1
fi
rm -f "$BUILD_DIR/$STAGED_BUILD_MARKER"
rm -rf "$OLD_DIR"
echo "==> Swapped the new build into $BUILD_DIR"
