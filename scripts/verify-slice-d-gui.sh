#!/bin/bash
# Slice D Importance-section manual GUI verification, on an isolated dev
# workspace/config/UserDefaults domain — never touches whatever real Slack
# workspace this machine's ~/.config/watchtower/config.yaml points at.
#
# Run from a clean checkout of this branch (feature/memory-phase5 with the
# Slice D commits + this branch's WATCHTOWER_CONFIG_PATH env-var override, see
# commit 10c5af5 "chore(dev): WATCHTOWER_CONFIG_PATH override for isolated
# Desktop GUI verification"). Requires:
#   - Xcode/Swift 6 toolchain for `swift build` (see CLAUDE.md)
#   - The terminal app running this script to have Accessibility permission
#     (System Settings -> Privacy & Security -> Accessibility) — macOS will
#     prompt on first `osascript ... System Events` call if not yet granted;
#     approve it and re-run.
#
# What it does, in order:
#   1. Builds the dev app (make app-dev).
#   2. Re-signs it ad-hoc under a distinct CFBundleIdentifier so its
#      UserDefaults (onboarding state, window frame, etc.) never collides
#      with a real Watchtower.app install's preferences domain.
#   3. Seeds a throwaway workspace (~/.local/share/watchtower/slice-d-verify)
#      with one memory vault entity node, reindexes it via the Go CLI's
#      --workspace override (never touches the real active_workspace).
#   4. Writes an isolated config.yaml and launches the app with
#      WATCHTOWER_CONFIG_PATH pointed at it (both the Swift app and any
#      `watchtower sync --daemon` child it spawns honor this — see the
#      commit above; without the Go-side half of that fix, the spawned
#      daemon silently falls back to the REAL config and can sync a REAL
#      workspace, which is exactly what happened during the original
#      manual check on 2026-07-26 before this fix existed).
#   5. Drives the Memory tab via System Events: select the seeded entity,
#      set an importance override, confirm it round-trips after navigating
#      away and back, clear it, confirm it's gone. Screenshots each step.
#   6. Quits the app and deletes every trace it created (workspace dir,
#      UserDefaults domain, temp config).
#
# Screenshots land in $OUT_DIR (default: ./slice-d-verify-screenshots),
# named 01-*.png .. NN-*.png in order.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUNDLE_ID="com.watchtower.desktop.slicedverify"
WORKSPACE_NAME="slice-d-verify"
WORKSPACE_DIR="$HOME/.local/share/watchtower/$WORKSPACE_NAME"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/slice-d-verify-screenshots}"
CONFIG_PATH="/tmp/watchtower-slice-d-verify-config.yaml"
APP="$PROJECT_ROOT/build/Watchtower.app"
GO_CLI="/tmp/watchtower-slice-d-verify-cli"

cleanup() {
  echo "==> Cleaning up"
  pkill -f "$WORKSPACE_NAME/build/Watchtower.app/Contents/MacOS/watchtower sync" 2>/dev/null || true
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  rm -rf "$WORKSPACE_DIR"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -f "$CONFIG_PATH" "$GO_CLI"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"
echo "==> Screenshots will land in $OUT_DIR"

echo "==> Step 1/6: building dev app (this can take several minutes on a cold cache)"
cd "$PROJECT_ROOT"
./scripts/build-app.sh --dev

echo "==> Step 2/6: isolating CFBundleIdentifier -> $BUNDLE_ID (own UserDefaults domain)"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
codesign -s - --force --deep "$APP"

echo "==> Step 3/6: seeding isolated workspace at $WORKSPACE_DIR"
rm -rf "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR/memory/entities"
(
  cd "$WORKSPACE_DIR/memory"
  git init -q
  git config user.name "Watchtower Verify"
  git config user.email "verify@watchtower.local"
  cat > entities/ent_00000000000000000000000001.md <<'EOF'
---
id: ent_00000000000000000000000001
type: entity
tier: long
status: active
aliases: ["test-entity"]
---
# Slice D Verification Entity

## What
A throwaway entity created only to visually verify the Slice D Importance section round-trip. Safe to delete.

## Current
No manual importance override set yet — this is what the GUI check exercises.

## Facts

## Links

## Open loops
EOF
  git add -A
  git commit -q -m "seed: slice-d verification entity"
)
go build -o "$GO_CLI" "$PROJECT_ROOT"
"$GO_CLI" --workspace="$WORKSPACE_NAME" memory reindex

echo "==> Step 4/6: writing isolated config + launching app"
cat > "$CONFIG_PATH" <<EOF
active_workspace: $WORKSPACE_NAME
EOF
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults write "$BUNDLE_ID" onboarding_current_step -int 6
defaults write "$BUNDLE_ID" pipelines_completed -bool true

WATCHTOWER_CONFIG_PATH="$CONFIG_PATH" "$APP/Contents/MacOS/WatchtowerDesktop" > /tmp/watchtower-slice-d-verify.log 2>&1 &
APP_PID=$!
echo "    launched pid $APP_PID"
sleep 4

# Watchdog: kill any sync daemon this test build spawns, belt-and-suspenders
# alongside the WATCHTOWER_CONFIG_PATH fix in cmd/root.go.
( while kill -0 "$APP_PID" 2>/dev/null; do
    pkill -f "$WORKSPACE_NAME/build/Watchtower.app/Contents/MacOS/watchtower sync" 2>/dev/null || true
    sleep 1
  done ) &
WATCHDOG_PID=$!

osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $APP_PID to true"
sleep 1
screencapture -x "$OUT_DIR/01-launch.png"

echo "==> Step 5/6: driving the Memory tab"
osascript <<APPLESCRIPT
tell application "System Events"
    set theProc to first process whose unix id is $APP_PID
    tell theProc
        -- Expand the INSIGHTS sidebar section and open Memory.
        click (first static text whose value is "INSIGHTS")
        delay 0.3
        click (first static text whose value is "Memory")
        delay 0.5
    end tell
end tell
APPLESCRIPT
screencapture -x "$OUT_DIR/02-memory-tab.png"

osascript <<APPLESCRIPT
tell application "System Events"
    tell (first process whose unix id is $APP_PID)
        click (first static text whose value is "Slice D Verification Entity")
        delay 0.5
    end tell
end tell
APPLESCRIPT
screencapture -x "$OUT_DIR/03-entity-selected.png"

osascript <<APPLESCRIPT
tell application "System Events"
    tell (first process whose unix id is $APP_PID)
        set overrideField to first text field whose description is "Override"
        click overrideField
        set value of overrideField to "5"
        click (first button whose title is "Save")
        delay 0.5
    end tell
end tell
APPLESCRIPT
screencapture -x "$OUT_DIR/04-override-set.png"

# Navigate away and back — confirms the value round-trips through a reselect,
# not just staying in the in-memory editor buffer.
osascript <<APPLESCRIPT
tell application "System Events"
    tell (first process whose unix id is $APP_PID)
        click (first static text whose value is "Targets")
        delay 0.3
        click (first static text whose value is "Memory")
        delay 0.3
        click (first static text whose value is "Slice D Verification Entity")
        delay 0.5
    end tell
end tell
APPLESCRIPT
screencapture -x "$OUT_DIR/05-override-persisted-after-reselect.png"

osascript <<APPLESCRIPT
tell application "System Events"
    tell (first process whose unix id is $APP_PID)
        click (first button whose title is "Clear override")
        delay 0.5
    end tell
end tell
APPLESCRIPT
screencapture -x "$OUT_DIR/06-override-cleared.png"

kill "$WATCHDOG_PID" 2>/dev/null || true

echo "==> Step 6/6: done — review screenshots in $OUT_DIR"
echo "    01: app launched (Inbox)"
echo "    02: Memory tab open, entity list visible"
echo "    03: seeded entity selected, Importance section visible (score 0.0, no override)"
echo "    04: override set to 5 and saved (\"manual override\" tag should appear)"
echo "    05: after navigating away and back — override should still read 5 (proves the write persisted, not just the in-memory field)"
echo "    06: override cleared (\"manual override\" tag should be gone, score back to 0.0)"
echo ""
echo "Cleanup (workspace dir, UserDefaults domain, temp config, app process) runs automatically on exit."
