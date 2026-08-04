#!/bin/bash
# Tests for the live-process guard of scripts/build-app.sh.
#
# Extracts the block verbatim (BEGIN/END markers) and runs it in a subshell
# against a stubbed `ps` binary and a synthetic BUILD_DIR — no real process
# list, no build (`make app` stays out of automated verification by design,
# doubly so here: the guard exists precisely because rebuilding under a live
# process breaks it).
#
# Covers:
#   - app running from build/Watchtower.app          → exit 1
#   - app running from build/dmg-staging/...         → exit 1 (the whole build
#     dir is the blast radius of `rm -rf "$BUILD_DIR"`, not just the bundle)
#   - standalone build/watchtower daemon with args   → exit 1
#   - clean process list (valid, degenerate)         → guard passes, exit 0
#   - BUILD_DIR containing a literal '+'             → exit 1 (worktree paths
#     carry regex metacharacters; the match must stay literal)
#   - build/ mentioned only in a later argv token    → guard passes (no false
#     positive on e.g. an editor or tail watching the directory)
#   - `ps` itself failing                            → guard aborts (fail closed)
#   - Info.plist pins LSMultipleInstancesProhibited to <true/>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"

FAILURES=0

note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

# 0. The whole script must at least parse.
if bash -n "$BUILD_APP"; then
    echo "ok: bash -n build-app.sh"
else
    note_fail "bash -n build-app.sh"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SNIPPET="$WORK_DIR/snippet.sh"
sed -n '/# BEGIN live-process-guard/,/# END live-process-guard/p' "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'RUNNING_FROM_BUILD' "$SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"

# make_ps_stub <exit-code>  — fixture text on stdin becomes the stub's output.
make_ps_stub() {
    cat > "$STUB_DIR/ps_fixture.txt"
    cat > "$STUB_DIR/ps" <<EOF
#!/bin/bash
cat "$STUB_DIR/ps_fixture.txt"
exit $1
EOF
    chmod +x "$STUB_DIR/ps"
}

# The block runs in a child bash PROCESS, not a subshell of this one (the one
# departure from test-build-app-signing.sh's `. "$SNIPPET"` pattern): a subshell
# spawned from a `$(...) || rc=$?` command inherits bash's "errexit is being
# ignored here" state, which would make the fail-closed case silently pass.
# A fresh process reproduces build-app.sh's own top-level `set -euo pipefail`.
RUNNER="$WORK_DIR/runner.sh"
cat > "$RUNNER" <<EOF
set -euo pipefail
BUILD_DIR="\$1"
. "$SNIPPET"
echo "GUARD=passed"
EOF

# run_guard <build_dir> — runs the block with \`ps\` stubbed first in PATH;
# prints GUARD=passed when the block falls through, propagates its exit code.
run_guard() {
    PATH="$STUB_DIR:$PATH" bash "$RUNNER" "$1"
}

# check <label> <haystack> <needle>
check() {
    case "$2" in
        *"$3"*) echo "ok: $1" ;;
        *)
            note_fail "$1"
            printf '  wanted substring: %s\n  got:\n%s\n' "$3" "$2"
            ;;
    esac
}

# The expectation helpers publish the run through globals rather than stdout:
# a `$(...)` capture would run note_fail in a subshell and lose the failure.
GUARD_OUT=""
GUARD_RC=0

# expect_blocked <label> <build_dir>  — guard must exit non-zero.
expect_blocked() {
    GUARD_RC=0
    GUARD_OUT=$(run_guard "$2" 2>&1) || GUARD_RC=$?
    if [ "$GUARD_RC" -eq 0 ]; then
        note_fail "$1 (guard let the build through)"
        printf '  got:\n%s\n' "$GUARD_OUT"
    else
        echo "ok: $1"
    fi
}

# expect_passed <label> <build_dir>  — guard must fall through with exit 0.
expect_passed() {
    GUARD_RC=0
    GUARD_OUT=$(run_guard "$2" 2>&1) || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        note_fail "$1 (rc=$GUARD_RC)"
        printf '  got:\n%s\n' "$GUARD_OUT"
    else
        check "$1" "$GUARD_OUT" "GUARD=passed"
    fi
}

BD="$WORK_DIR/project/build"
PLUS_BD="$WORK_DIR/feature+x/build"

# --- 1. The app bundle itself ------------------------------------------------
make_ps_stub 0 <<EOF
/sbin/launchd
$BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
/usr/libexec/secinitd
EOF
expect_blocked "running app blocks the rebuild" "$BD"
check "error names the build dir" "$GUARD_OUT" "$BD"
check "error prints the matched command line" "$GUARD_OUT" "$BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop"

# --- 2. dmg-staging copy — outside the bundle, inside the blast radius --------
make_ps_stub 0 <<EOF
$BD/dmg-staging/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_blocked "dmg-staging copy blocks the rebuild" "$BD"
check "dmg-staging error prints the matched command line" "$GUARD_OUT" "$BD/dmg-staging/"

# --- 3. Standalone Go binary (the bundled daemon's twin) ---------------------
make_ps_stub 0 <<EOF
$BD/watchtower daemon --interval 5m
EOF
expect_blocked "standalone build/watchtower blocks the rebuild" "$BD"
check "daemon error mentions the daemon case" "$GUARD_OUT" "daemon"

# --- 4. Clean process list (valid, degenerate input) -------------------------
make_ps_stub 0 <<EOF
/sbin/launchd
/usr/sbin/cfprefsd agent
/Applications/Safari.app/Contents/MacOS/Safari
EOF
expect_passed "unrelated processes let the build proceed" "$BD"

# --- 5. Path metacharacters stay literal (worktree names carry '+') ----------
make_ps_stub 0 <<EOF
$PLUS_BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_blocked "'+' in BUILD_DIR still matches (literal, not regex)" "$PLUS_BD"
check "'+' error prints the matched command line" "$GUARD_OUT" "$PLUS_BD/Watchtower.app"

# A '+' path must not be read as a regex against a NON-matching process either:
# 'feature+x' as a pattern would match 'featurexx'.
make_ps_stub 0 <<EOF
$WORK_DIR/featurexx/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_passed "'+' is not treated as a repetition operator" "$PLUS_BD"

# --- 6. build/ only as a later argv token → no false positive ----------------
make_ps_stub 0 <<EOF
/usr/bin/tail -f $BD/watchtower.log
/bin/ls $BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_passed "build/ mentioned in argv does not trip the guard" "$BD"

# --- 7. ps failure → fail closed --------------------------------------------
make_ps_stub 1 <<EOF
ps: some catastrophe
EOF
RC=0
OUT=$(run_guard "$BD" 2>&1) || RC=$?
if [ "$RC" -ne 0 ]; then
    echo "ok: failing ps aborts the build (fail closed)"
else
    note_fail "failing ps aborts the build (got rc=0)"
    printf '  got:\n%s\n' "$OUT"
fi
case "$OUT" in
    *GUARD=passed*) note_fail "failing ps must not fall through to the build" ;;
    *) echo "ok: failing ps does not fall through" ;;
esac

# --- 8. Info.plist pin -------------------------------------------------------
# Load-bearing flag with no runtime assertion elsewhere: LaunchServices reads it
# from the shipped plist, so pin the heredoc text.
if grep -A1 '<key>LSMultipleInstancesProhibited</key>' "$BUILD_APP" | grep -q '<true/>'; then
    echo "ok: Info.plist sets LSMultipleInstancesProhibited to <true/>"
else
    note_fail "Info.plist sets LSMultipleInstancesProhibited to <true/>"
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) FAILED"
    exit 1
fi
echo "All live-process-guard tests passed."
