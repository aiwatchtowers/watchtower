#!/usr/bin/env bash
# Throwaway S0 spike: generate the Xcode project and build both targets.
# Signing team comes from the environment; nothing personal is stored in the repo.
#
#   DEVELOPMENT_TEAM=<team-id> ./spike.sh <command>
#
# Commands:
#   gen               regenerate CKSpike.xcodeproj (xcodegen)
#   check             unsigned builds: macOS, iOS device (CODE_SIGNING_ALLOWED=NO), iOS simulator
#   mac               signed macOS build (automatic signing, needs DEVELOPMENT_TEAM)
#   ios               signed iOS device build (automatic signing, needs DEVELOPMENT_TEAM)
#   ios-install <udid>  signed iOS build, then install on the connected device
#
# Optional overrides: SPIKE_MAC_BUNDLE_ID, SPIKE_IOS_BUNDLE_ID.
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
export SPIKE_MAC_BUNDLE_ID="${SPIKE_MAC_BUNDLE_ID:-com.aiwatchtowers.watchtower.ckspike}"
export SPIKE_IOS_BUNDLE_ID="${SPIKE_IOS_BUNDLE_ID:-com.aiwatchtowers.watchtower.mobile}"

PROJECT=CKSpike.xcodeproj
DERIVED=build

gen() { xcodegen generate --quiet; }

need_team() {
  if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    echo "DEVELOPMENT_TEAM is not set (your Apple Developer team id)" >&2
    exit 2
  fi
}

cmd="${1:-}"
case "$cmd" in
  gen)
    gen ;;
  check)
    gen
    xcodebuild -project "$PROJECT" -scheme CKSpikeMac -configuration Debug \
      -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED/mac-unsigned" \
      CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project "$PROJECT" -scheme CKSpikeiOS -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED/ios-unsigned" \
      CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project "$PROJECT" -scheme CKSpikeiOS -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED/ios-sim" \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  mac)
    need_team; gen
    xcodebuild -project "$PROJECT" -scheme CKSpikeMac -configuration Debug \
      -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED/mac" \
      -allowProvisioningUpdates build
    echo "binary: $PWD/$DERIVED/mac/Build/Products/Debug/CKSpikeMac.app/Contents/MacOS/CKSpikeMac"
    ;;
  ios)
    need_team; gen
    xcodebuild -project "$PROJECT" -scheme CKSpikeiOS -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED/ios" \
      -allowProvisioningUpdates build
    echo "app: $PWD/$DERIVED/ios/Build/Products/Debug-iphoneos/CKSpike.app"
    ;;
  ios-install)
    udid="${2:?usage: spike.sh ios-install <device-udid>  (xcrun devicectl list devices)}"
    "$0" ios
    xcrun devicectl device install app --device "$udid" "$DERIVED/ios/Build/Products/Debug-iphoneos/CKSpike.app"
    ;;
  *)
    sed -n '2,16p' "$0"; exit 2 ;;
esac
