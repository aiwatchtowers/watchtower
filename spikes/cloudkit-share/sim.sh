#!/usr/bin/env bash
# Throwaway S0 spike: run (d) "same Apple ID" and (e) on an iOS simulator signed into the Mac's
# Apple ID. The simulator stands in for iPhone 1; a pass here is indicative, the device run decides.
#
#   ./sim.sh install <udid>   install the simulator build (build it first: DEVELOPMENT_TEAM=… ./spike.sh sim)
#   ./sim.sh run <udid>       link → (d) same → (e) subscribe → Mac alerts → (e) read; prints the RESULT lines
#
# Needs: `./spike.sh mac` built, `spike setup` run once (the link is read from the Mac log),
# the simulator signed into iCloud with the Mac's Apple ID, and the Queryable `kind` index (README step 0.3).
set -euo pipefail
cd "$(dirname "$0")"

IOS_BUNDLE="${SPIKE_IOS_BUNDLE_ID:-com.aiwatchtowers.watchtower.mobile}"
MAC_BIN="$PWD/build/mac/Build/Products/Debug/CKSpikeMac.app/Contents/MacOS/CKSpikeMac"
MAC_LOG="$HOME/Library/Application Support/CKSpike/spike-mac.log"
SIM_APP="build/ios-sim-signed/Build/Products/Debug-iphonesimulator/CKSpike.app"

# Strips record names, share URLs and the link before anything is shown or pasted.
redact() {
  sed -E 's/_[0-9a-f]{20,}/<record>/g; s#https://www\.icloud\.com/share/[^ ,]*#<share-url>#g; s#ckspike://link\?[^ ]*#<link>#g'
}

cmd="${1:-}"
udid="${2:-}"
[[ -n "$udid" ]] || { sed -n '2,9p' "$0"; exit 2; }

case "$cmd" in
  install)
    xcrun simctl install "$udid" "$SIM_APP"
    ;;
  run)
    link=$(grep -Eo 'ckspike://link\?[^ ]+' "$MAC_LOG" | tail -1)
    [[ -n "$link" ]] || { echo "no LINK in the Mac log: run \`spike setup\` first" >&2; exit 2; }
    # Launch arguments, not `simctl openurl`: a custom-URL open stops at an "Open in…?" prompt.
    item() { xcrun simctl launch --terminate-running-process "$udid" "$IOS_BUNDLE" "$@" >/dev/null; }
    item
    log="$(xcrun simctl get_app_container "$udid" "$IOS_BUNDLE" data)/Documents/ckspike.log"
    start=$(wc -l < "$log" 2>/dev/null || echo 0)
    run_log=$(mktemp -t ckspike-sim)
    trap 'rm -f "$run_log"' EXIT
    fresh() { tail -n +"$((start + 1))" "$log" > "$run_log" 2>/dev/null || true; }
    # wait_run <extended regex> <count> <seconds>: bounded wait for this run's log lines.
    wait_run() {
      local i
      for ((i = 0; i < $3; i++)); do
        fresh
        [[ $(grep -Ec "$1" "$run_log") -ge $2 ]] && return 0
        sleep 1
      done
      echo "timed out after ${3}s waiting for: $1" >&2
    }

    item -ckspikeLink "$link" -ckspikeRun d-same
    wait_run 'RESULT \(d\)' 1 60

    echo "(e) subscribing: click Allow on the simulator's notification prompt if it appears"
    item -ckspikeRun e-subscribe
    wait_run 'now lock the iPhone' 1 120
    # Background the app, so the alerts are shown as banners and land in Notification Center.
    xcrun simctl launch "$udid" com.apple.mobilesafari >/dev/null
    "$MAC_BIN" alert DataZone
    sleep 30
    "$MAC_BIN" alert AlertZone
    sleep 30
    item -ckspikeRun e-read
    wait_run 'RESULT \(e\)' 2 60
    echo "---- simulator log, this run (redacted) ----"
    redact < "$run_log"
    ;;
  *)
    sed -n '2,9p' "$0"; exit 2 ;;
esac
