#!/bin/bash
# Tests for the retired-slack-id-check block in scripts/build-app.sh (#1709): a public release must set
# RETIRED_SLACK_CLIENT_ID. The block is extracted verbatim (BEGIN/END markers) and run in a subshell.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

sed -n '/# BEGIN retired-slack-id-check/,/# END retired-slack-id-check/p' "$BUILD_APP" > "$WORK_DIR/block.sh"
if [ ! -s "$WORK_DIR/block.sh" ]; then
    echo "FAIL: block retired-slack-id-check not found in build-app.sh — markers moved?"
    exit 1
fi

FAILURES=0
WANT_ERR="ERROR: a public release must set RETIRED_SLACK_CLIENT_ID (recognises accounts on the retired shared Slack app)"

# run <name> <expect: pass|fail> <dev> <flavor> <notarize> <id>
run() {
    local name="$1" expect="$2" dev="$3" flavor="$4" notarize="$5" id="$6" out rc
    out=$(DEV_MODE="$dev" FLAVOR="$flavor" NOTARIZE_PROFILE="$notarize" RETIRED_SLACK_CLIENT_ID="$id" \
        bash -c 'source "$1"; echo reached' _ "$WORK_DIR/block.sh" 2>&1)
    rc=$?
    if [ "$expect" = wsfail ]; then
        if [ "$rc" -eq 1 ] && [[ "$out" == *"must be a single token"* ]] && [[ "$out" != *reached* ]]; then
            echo "ok: $name"
        else
            echo "FAIL: $name (rc=$rc)"; echo "$out"; FAILURES=$((FAILURES + 1))
        fi
    elif [ "$expect" = fail ]; then
        if [ "$rc" -eq 1 ] && [[ "$out" == *"$WANT_ERR"* ]] && [[ "$out" != *reached* ]]; then
            echo "ok: $name"
        else
            echo "FAIL: $name (rc=$rc)"; echo "$out"; FAILURES=$((FAILURES + 1))
        fi
    else
        if [ "$rc" -eq 0 ] && [[ "$out" == *reached* ]]; then
            echo "ok: $name"
        else
            echo "FAIL: $name (rc=$rc)"; echo "$out"; FAILURES=$((FAILURES + 1))
        fi
    fi
}

run "public release, empty id fails (flavor empty)" fail false "" notarize-prof ""
run "public release, empty id fails (flavor dev)" fail false dev notarize-prof ""
run "public release with id passes" pass false "" notarize-prof placeholder-id
run "whitespace-only id fails" wsfail false "" notarize-prof "   "
run "embedded-space id fails" wsfail false "" notarize-prof "abc def"
run "corp release passes without id" pass false corp notarize-prof ""
run "--dev passes without id" pass true "" notarize-prof ""
run "non-release passes without id" pass false "" "" ""

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
