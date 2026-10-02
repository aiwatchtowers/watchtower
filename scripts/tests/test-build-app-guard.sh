#!/bin/bash
# Tests for the live-process guard (`running_from` in scripts/lib/app-guard.sh,
# used by build-app.sh's final swap via app-swap.sh, and by app-install.sh).
#
# Extracts the block verbatim (BEGIN/END markers) and runs it in a child bash
# process against a stubbed `ps` binary and a synthetic BUILD_DIR — no real
# process list, no build (`make app` stays out of automated verification by
# design, doubly so here: the guard exists precisely because swapping a build
# under a live process breaks it). The swap/defer decisions built on top of it
# are covered by test-app-swap.sh and test-app-install.sh.
#
# Covers:
#   - app running from build/Watchtower.app          → blocked
#   - app running from build/dmg-staging/...         → blocked (the swap
#     replaces the whole build dir, not just the bundle)
#   - standalone build/watchtower daemon with args   → blocked
#   - clean process list (valid, degenerate)         → guard passes
#   - BUILD_DIR containing a literal '+'             → blocked (worktree paths
#     carry regex metacharacters; the match must stay literal)
#   - BUILD_DIR containing a space                   → blocked (the path must be
#     matched whole-line, not as ps's first whitespace-delimited field)
#   - build/ mentioned only in a later argv token    → guard passes (no false
#     positive on e.g. an editor or tail watching the directory)
#   - a sibling '<build>-other' directory            → guard passes (the trailing
#     slash of the prefix is load-bearing)
#   - `ps` itself failing                            → lookup fails (fail closed)
#   - Info.plist pins LSMultipleInstancesProhibited to <true/>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"
GUARD_LIB="$SCRIPT_DIR/../lib/app-guard.sh"

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
END_MARKER="# END live-process-guard"
sed -n "/# BEGIN live-process-guard/,/$END_MARKER/p" "$GUARD_LIB" > "$SNIPPET"
if ! grep -q 'running_from()' "$SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in lib/app-guard.sh?"
    exit 1
fi
# Without the END marker sed prints to EOF, so the "snippet" would be the whole
# rest of the file. Refuse to run that.
if [ "$(tail -n 1 "$SNIPPET")" != "$END_MARKER" ]; then
    echo "FAIL: extracted block does not end at '$END_MARKER' — END marker lost, extraction ran to EOF"
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
# A fresh process reproduces the callers' own top-level `set -euo pipefail`.
# The runner mirrors app-swap.sh's use of the function: a failed lookup or any
# matched process blocks (exit 1), printing the matched lines.
RUNNER="$WORK_DIR/runner.sh"
cat > "$RUNNER" <<EOF
set -euo pipefail
BUILD_DIR="\$1"
. "$SNIPPET"
RUNNING=\$(running_from "\$BUILD_DIR") || { echo "GUARD=lookup-failed"; exit 1; }
if [ -n "\$RUNNING" ]; then
    printf '%s\n' "\$RUNNING"
    exit 1
fi
echo "GUARD=passed"
EOF

# run_guard <build_dir> — runs the block with \`ps\` stubbed first in PATH;
# prints GUARD=passed when nothing runs from <build_dir>, exits 1 otherwise.
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

# The expectation helpers publish the run's output through a global rather than
# stdout: a `$(...)` capture would run note_fail in a subshell and lose the
# failure. The exit code stays local — callers assert on GUARD_OUT.
GUARD_OUT=""

# expect_blocked <label> <build_dir>  — guard must exit non-zero.
expect_blocked() {
    local rc=0
    GUARD_OUT=$(run_guard "$2" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        note_fail "$1 (guard let the swap through)"
        printf '  got:\n%s\n' "$GUARD_OUT"
    else
        echo "ok: $1"
    fi
}

# expect_passed <label> <build_dir>  — guard must fall through with exit 0.
expect_passed() {
    local rc=0
    GUARD_OUT=$(run_guard "$2" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        note_fail "$1 (rc=$rc)"
        printf '  got:\n%s\n' "$GUARD_OUT"
    else
        check "$1" "$GUARD_OUT" "GUARD=passed"
    fi
}

BD="$WORK_DIR/project/build"
PLUS_BD="$WORK_DIR/feature+x/build"
SPACE_BD="$WORK_DIR/my worktree/build"

# --- 1. The app bundle itself ------------------------------------------------
make_ps_stub 0 <<EOF
/sbin/launchd
$BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
/usr/libexec/secinitd
EOF
expect_blocked "running app blocks the swap" "$BD"
check "the matched command line is reported" "$GUARD_OUT" "$BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop"

# --- 2. dmg-staging copy — outside the bundle, inside the swapped dir ---------
make_ps_stub 0 <<EOF
$BD/dmg-staging/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_blocked "dmg-staging copy blocks the swap" "$BD"
check "dmg-staging match reports the command line" "$GUARD_OUT" "$BD/dmg-staging/"

# --- 3. Standalone Go binary (the bundled daemon's twin) ---------------------
make_ps_stub 0 <<EOF
$BD/watchtower daemon --interval 5m
EOF
expect_blocked "standalone build/watchtower blocks the swap" "$BD"
check "daemon match reports the command line" "$GUARD_OUT" "$BD/watchtower daemon"

# --- 4. Clean process list (valid, degenerate input) -------------------------
make_ps_stub 0 <<EOF
/sbin/launchd
/usr/sbin/cfprefsd agent
/Applications/Safari.app/Contents/MacOS/Safari
EOF
expect_passed "unrelated processes let the swap proceed" "$BD"

# --- 5. Path metacharacters stay literal (worktree names carry '+') ----------
make_ps_stub 0 <<EOF
$PLUS_BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_blocked "'+' in BUILD_DIR still matches (literal, not regex)" "$PLUS_BD"
check "'+' match reports the command line" "$GUARD_OUT" "$PLUS_BD/Watchtower.app"

# A '+' path must not be read as a regex against a NON-matching process either:
# 'feature+x' as a pattern would match 'featurexx'.
make_ps_stub 0 <<EOF
$WORK_DIR/featurexx/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_passed "'+' is not treated as a repetition operator" "$PLUS_BD"

# --- 5b. A space in BUILD_DIR must not truncate the match --------------------
# ps output is whitespace-delimited, so matching only the first field would cut
# this path at 'my' and let the swap proceed under the live app.
make_ps_stub 0 <<EOF
$SPACE_BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_blocked "space in BUILD_DIR still matches (whole-line prefix)" "$SPACE_BD"
check "space match reports the command line" "$GUARD_OUT" "$SPACE_BD/Watchtower.app"

# --- 6. build/ only as a later argv token → no false positive ----------------
make_ps_stub 0 <<EOF
/usr/bin/tail -f $BD/watchtower.log
/bin/ls $BD/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_passed "build/ mentioned in argv does not trip the guard" "$BD"

# A sibling directory sharing the prefix is outside the swapped dir: the
# trailing slash on the compared prefix is what keeps it out.
make_ps_stub 0 <<EOF
${BD}-other/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
expect_passed "a sibling '<build>-other' directory does not trip the guard" "$BD"

# --- 7. ps failure → fail closed --------------------------------------------
make_ps_stub 1 <<EOF
ps: some catastrophe
EOF
expect_blocked "failing ps blocks the swap (fail closed)" "$BD"
check "failing ps is reported as a lookup failure" "$GUARD_OUT" "GUARD=lookup-failed"
case "$GUARD_OUT" in
    *GUARD=passed*) note_fail "failing ps must not fall through to the swap" ;;
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
