#!/usr/bin/env bash
# hub-keychain-check.sh — the real-Mac Keychain check of Go hub phase 3,
# Task 1 (spec §12.2). Run it by hand from Terminal on a Mac with the
# release signing identity installed:
#
#   scripts/hub-keychain-check.sh
#
# It builds two `watchtower` binaries of different versions, signs both the
# way scripts/build-app.sh signs Contents/MacOS/watchtower (the same
# identity selection, identifier `watchtower`, hardened runtime, no
# entitlements), and runs the hidden `hub keychain-probe` in two contexts,
# Terminal (this shell) and a LaunchAgent (a temporary user agent in a temp
# plist, removed afterwards):
#
#   older build: write   — creates four throwaway items
#   newer build: read    — what every daemon start after an update does
#   newer build: delete  — what a newer build's hand-over or reset does
#
# Every step prints `ok` or the failed call's OSStatus class; the last line
# is `result: ok` (KeychainUsable = true) or `result: fail` (the release
# build sets KeychainBuildFlag=false: file store). The probe uses its own
# service, never com.watchtower.hub, and the older build deletes whatever
# is left at the end. Exit codes: 0 ok, 1 fail, 2 could not run.
set -uo pipefail

# The probe is refused under an agent marker; refuse here first, so no step
# (and no cleanup) runs half-refused and leaves items behind.
for marker in CLAUDECODE CODEX_THREAD_ID CODEX_SANDBOX WATCHTOWER_TERMINAL_SESSION_ID WATCHTOWER_AUTOMATION_RUN_ID; do
    if [ -n "${!marker:-}" ]; then
        echo "could not run: $marker is set — run this from a plain Terminal, not under an AI agent"
        exit 2
    fi
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="watchtower-hub-keychain-probe-$$"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wt-hub-keychain-check.XXXXXX")"
LABEL="com.watchtower.hub-keychain-check.$$"
PLIST="$WORK/$LABEL.plist"
STEP_TIMEOUT=30

cleanup() {
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    if [ -x "$WORK/watchtower-a" ]; then
        "$WORK/watchtower-a" hub keychain-probe delete --service "$SERVICE" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# The signing identity, chosen exactly as scripts/build-app.sh chooses it
# (the block is extracted verbatim, as its tests do). DEV_MODE=true: a
# missing identity is reported here instead of failing a release build.
DEV_MODE=true
SELECTION="$(sed -n '/^# BEGIN signing-identity-selection/,/^# END signing-identity-selection/p' "$ROOT/scripts/build-app.sh")"
if [ -z "$SELECTION" ]; then
    echo "could not run: the signing-identity-selection block is missing from scripts/build-app.sh"
    exit 2
fi
eval "$SELECTION"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "could not run: no signing identity ($ADHOC_REASON)"
    exit 2
fi
echo "==> signing identity: $SIGN_IDENTITY"

build() { # build <out> <version>
    (cd "$ROOT" && go build -ldflags "-X watchtower/cmd.Version=$2" -o "$1" .) || return 1
    codesign --force --options runtime --timestamp=none --identifier watchtower --sign "$SIGN_IDENTITY" "$1" >/dev/null 2>&1
}
echo "==> building two signed versions"
if ! build "$WORK/watchtower-a" 0.0.1-keychain-check-a || ! build "$WORK/watchtower-b" 0.0.1-keychain-check-b; then
    echo "could not run: build or signing failed"
    exit 2
fi
if cmp -s "$WORK/watchtower-a" "$WORK/watchtower-b"; then
    echo "could not run: the two builds are identical"
    exit 2
fi

# probe <binary> <step>: one step, bounded (a Keychain prompt would block).
probe() {
    perl -e 'alarm shift; exec @ARGV' "$STEP_TIMEOUT" \
        "$1" hub keychain-probe "$2" --service "$SERVICE" 2>&1 | tail -1
    local rc=${PIPESTATUS[0]}
    [ "$rc" -eq 142 ] && echo "$2: timed out (a Keychain prompt?)"
}

# The steps of one context; the caller reads three lines.
STEPS='printf "write %s\n" "$(probe "$A" write)"; printf "read %s\n" "$(probe "$B" read)"; printf "delete %s\n" "$(probe "$B" delete)"'

run_terminal() {
    A="$WORK/watchtower-a" B="$WORK/watchtower-b"
    eval "$STEPS"
    "$A" hub keychain-probe delete --service "$SERVICE" >/dev/null 2>&1 || true
}

run_launchagent() {
    local out="$WORK/launchagent.out" runner="$WORK/launchagent.sh"
    {
        echo '#!/usr/bin/env bash'
        echo "SERVICE='$SERVICE' STEP_TIMEOUT=$STEP_TIMEOUT"
        declare -f probe
        echo "A='$WORK/watchtower-a' B='$WORK/watchtower-b'"
        echo "$STEPS"
        echo '"$A" hub keychain-probe delete --service "$SERVICE" >/dev/null 2>&1'
        echo 'echo done'
    } >"$runner"
    chmod 700 "$runner"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>/bin/bash</string><string>$runner</string></array>
    <key>StandardOutPath</key><string>$out</string>
    <key>StandardErrorPath</key><string>$WORK/launchagent.err</string>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
        echo "write could not start a LaunchAgent"
        return
    fi
    local waited=0
    while ! grep -q '^done$' "$out" 2>/dev/null && [ "$waited" -lt $((4 * STEP_TIMEOUT)) ]; do
        sleep 1
        waited=$((waited + 1))
    done
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    grep -v '^done$' "$out" 2>/dev/null || echo "write produced no output"
    "$WORK/watchtower-a" hub keychain-probe delete --service "$SERVICE" >/dev/null 2>&1 || true
}

result=ok
report() { # report <context> <lines>
    while read -r step answer; do
        [ -n "$step" ] || continue
        echo "$1 $step: $answer"
        [ "$answer" = ok ] || result=fail
    done <<<"$2"
}
report terminal "$(run_terminal)"
report launchagent "$(run_launchagent)"
echo "result: $result"
[ "$result" = ok ]
