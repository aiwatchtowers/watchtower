#!/bin/bash
# Tests for the retired-slack-id-check block in scripts/build-app.sh (#1709): a public release must set
# RETIRED_SLACK_CLIENT_ID; no release bakes a Slack client secret; a public release does not bake the
# retired id as its own (A15). The block is extracted verbatim (BEGIN/END markers) and run in a subshell.
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
WANT_SECRET_ERR="ERROR: a release must not set WATCHTOWER_OAUTH_CLIENT_SECRET"
WANT_RETIRED_ERR="ERROR: a public release must not set WATCHTOWER_OAUTH_CLIENT_ID to RETIRED_SLACK_CLIENT_ID"

# expect_fail <name> <rc> <out> <wanted message>
expect_fail() {
    local name="$1" rc="$2" out="$3" want="$4"
    if [ "$rc" -eq 1 ] && [[ "$out" == *"$want"* ]] && [[ "$out" != *reached* ]]; then
        echo "ok: $name"
    else
        echo "FAIL: $name (rc=$rc)"; echo "$out"; FAILURES=$((FAILURES + 1))
    fi
}

# run <name> <expect: pass|fail|wsfail|secretfail|retiredfail> <dev> <flavor> <notarize> <id> [<oauth id> <oauth secret>]
run() {
    local name="$1" expect="$2" dev="$3" flavor="$4" notarize="$5" id="$6" oauth_id="${7:-}" oauth_secret="${8:-}" out rc
    out=$(DEV_MODE="$dev" FLAVOR="$flavor" NOTARIZE_PROFILE="$notarize" RETIRED_SLACK_CLIENT_ID="$id" \
        WATCHTOWER_OAUTH_CLIENT_ID="$oauth_id" WATCHTOWER_OAUTH_CLIENT_SECRET="$oauth_secret" \
        bash -c 'source "$1"; echo reached' _ "$WORK_DIR/block.sh" 2>&1)
    rc=$?
    if [ "$expect" = wsfail ]; then
        expect_fail "$name" "$rc" "$out" "must be a single token"
    elif [ "$expect" = fail ]; then
        expect_fail "$name" "$rc" "$out" "$WANT_ERR"
    elif [ "$expect" = secretfail ]; then
        expect_fail "$name" "$rc" "$out" "$WANT_SECRET_ERR"
    elif [ "$expect" = retiredfail ]; then
        expect_fail "$name" "$rc" "$out" "$WANT_RETIRED_ERR"
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
# A15 (Task 18): no release bakes a Slack client secret; a public release does not bake the retired id.
run "public release with a Slack secret fails" secretfail false "" notarize-prof placeholder-id "" placeholder-secret
run "corp release with a Slack secret fails" secretfail false corp notarize-prof "" placeholder-corp-id placeholder-secret
run "public release baking the retired id fails" retiredfail false "" notarize-prof placeholder-id placeholder-id ""
run "corp release with an id and no secret passes" pass false corp notarize-prof "" placeholder-corp-id ""
run "public release with neither id nor secret passes" pass false "" notarize-prof placeholder-id "" ""
run "dev-flavor release with a Slack secret fails" secretfail false dev notarize-prof placeholder-id "" placeholder-secret
run "dev-flavor release baking the retired id fails" retiredfail false dev notarize-prof placeholder-id placeholder-id ""
run "public release with the retired id and a secret fails on the secret first" secretfail false "" notarize-prof placeholder-id placeholder-id placeholder-secret
run "--dev passes with a Slack secret" pass true "" notarize-prof "" placeholder-dev-id placeholder-secret
run "non-release passes with a Slack secret" pass false "" "" "" placeholder-dev-id placeholder-secret

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
