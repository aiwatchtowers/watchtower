#!/bin/bash
# Promotes the finished staged build (build.next/) to build/.
#
# scripts/build-app.sh builds into build.next/ and runs this at the end, so the
# long build never touches build/ — the owner can keep running the app from
# build/Watchtower.app meanwhile. The swap itself only happens while nothing
# executes from build/ or build.next/ (see scripts/lib/app-guard.sh for why).
#
# Usage: make app-swap            (or scripts/app-swap.sh)
#        WAIT=1 make app-swap     wait for the owner to quit the app, then swap
#
# Exit codes: 0 swapped; 1 error (no or incomplete staged build, an app running
# from build.next/, ps failure, WAIT timeout); 3 deferred — something runs from
# build/, staged build kept.
set -euo pipefail

# pwd -P: ps reports the resolved path LaunchServices launched, so the guard
# prefix must not carry symlinked components.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
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

# Moving build.next/ under a process launched from it is the same breakage as
# replacing build/ under one — and after the move ps would still report the
# old path, hiding it from every later guard.
RUNNING=$(running_from "$STAGE_DIR") || {
    echo "ERROR: could not read the process list (ps failed) — refusing to move $STAGE_DIR" >&2
    exit 1
}
if [ -n "$RUNNING" ]; then
    echo "ERROR: a Watchtower process is running from $STAGE_DIR — quit it, then run 'make app-swap':" >&2
    printf '%s\n' "$RUNNING" >&2
    exit 1
fi

# Clear a leftover from an interrupted swap before the guard, so nothing slow
# runs between the guard and the renames.
rm -rf "$OLD_DIR"

if [ "${WAIT:-}" = "1" ]; then
    wait_until_free "$BUILD_DIR" || exit 1
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

replace_dir "$STAGE_DIR" "$BUILD_DIR" "$OLD_DIR" || exit 1
rm -f "$BUILD_DIR/$STAGED_BUILD_MARKER"
echo "==> Swapped the new build into $BUILD_DIR"
