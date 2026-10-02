#!/bin/bash
# Tests for the staged build: scripts/app-swap.sh (promotes build.next/ to
# build/) and build-app.sh's finish-staged-build block (how a build reacts to
# a swap that happened, was deferred, or failed).
#
# app-swap.sh runs for real inside a temp project tree (its PROJECT_ROOT is
# derived from its own location) with `ps` stubbed first in PATH — no real
# process list, no build. The build-app.sh block is extracted verbatim
# (BEGIN/END markers) and run against a stub app-swap.sh.
#
# Covers:
#   - no staged build                          → exit 1, "run 'make app'"
#   - staged build without the completion marker (failed build) → exit 1
#   - nothing runs from build/                 → swapped; staging, build.old and
#     the marker are gone (the CI / clean-machine layout)
#   - first build, no build/ yet               → swapped
#   - the app runs from build/                 → exit 3, build/ and staging
#     untouched, message names the process and `make app-swap`
#   - ps fails                                 → exit 1, nothing touched
#   - WAIT=1, app quits while waiting          → swapped after the prompt
#   - WAIT=1, app never quits                  → exit 1 after WAIT_TIMEOUT
#   - project path with a space and a '+'      → deferral and swap both work
#   - build-app.sh: swap ok → OUT_DIR=build/; deferred → exit 0, OUT_DIR=staging,
#     banner names `make app-swap`; swap error → build fails
#   - build-app.sh never writes to $BUILD_DIR itself (only the swap does)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/.."
BUILD_APP="$SCRIPTS/build-app.sh"

FAILURES=0

note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
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

# check_eq <label> <got> <want>
check_eq() {
    if [ "$2" = "$3" ]; then
        echo "ok: $1"
    else
        note_fail "$1 (got '$2', want '$3')"
    fi
}

# check_test <ok-label> <fail-label> <test(1) expression...>
check_test() {
    local ok="$1" fail="$2"
    shift 2
    if [ "$@" ]; then
        echo "ok: $ok"
    else
        note_fail "$fail"
    fi
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"

# make_ps_stub <exit-code> [running-calls] — fixture text on stdin is what the
# stub prints. With running-calls=N the fixture is printed only on the first N
# calls and an empty process list afterwards (the owner quitting the app).
make_ps_stub() {
    cat > "$STUB_DIR/ps_fixture.txt"
    rm -f "$STUB_DIR/ps_calls"
    cat > "$STUB_DIR/ps" <<EOF
#!/bin/bash
n=\$(cat "$STUB_DIR/ps_calls" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$STUB_DIR/ps_calls"
limit="${2:-}"
if [ -z "\$limit" ] || [ "\$n" -le "\$limit" ]; then
    cat "$STUB_DIR/ps_fixture.txt"
fi
exit $1
EOF
    chmod +x "$STUB_DIR/ps"
}

# make_tree <root> <with-build:yes|no> <staging:complete|incomplete|none>
# A fake project: the real scripts under test, a build/ holding "old" and a
# build.next/ holding "new".
make_tree() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/scripts/lib"
    cp "$SCRIPTS/app-swap.sh" "$root/scripts/"
    cp "$SCRIPTS/lib/app-guard.sh" "$root/scripts/lib/"
    if [ "$2" = yes ]; then
        mkdir -p "$root/build/Watchtower.app/Contents"
        echo old > "$root/build/Watchtower.app/Contents/version"
    fi
    if [ "$3" != none ]; then
        mkdir -p "$root/build.next/Watchtower.app/Contents"
        echo new > "$root/build.next/Watchtower.app/Contents/version"
    fi
    if [ "$3" = complete ]; then
        touch "$root/build.next/.build-complete"
    fi
}

# version_of <dir> — the fake bundle's version, or "missing".
version_of() {
    cat "$1/Watchtower.app/Contents/version" 2>/dev/null || echo missing
}

OUT=""
RC=0
# run_swap <root> [VAR=value...] — runs the tree's app-swap.sh with ps stubbed.
run_swap() {
    local root="$1"
    shift
    RC=0
    OUT=$(env PATH="$STUB_DIR:$PATH" "$@" bash "$root/scripts/app-swap.sh" 2>&1) || RC=$?
}

ROOT="$WORK_DIR/project"
CLEAN_PS="/sbin/launchd
/Applications/Safari.app/Contents/MacOS/Safari"

# --- 1. No staged build ------------------------------------------------------
make_tree "$ROOT" yes none
make_ps_stub 0 <<< "$CLEAN_PS"
run_swap "$ROOT"
check_eq "no staged build exits 1" "$RC" 1
check "no staged build points at make app" "$OUT" "run 'make app' first"
check_eq "no staged build leaves build/ alone" "$(version_of "$ROOT/build")" old

# --- 2. Incomplete staged build (the last build failed) ----------------------
make_tree "$ROOT" yes incomplete
run_swap "$ROOT"
check_eq "incomplete staging exits 1" "$RC" 1
check "incomplete staging is named as such" "$OUT" "incomplete"
check_eq "incomplete staging leaves build/ alone" "$(version_of "$ROOT/build")" old

# --- 3. Nothing runs from build/ → swap -------------------------------------
make_tree "$ROOT" yes complete
make_ps_stub 0 <<< "$CLEAN_PS"
run_swap "$ROOT"
check_eq "clean swap exits 0" "$RC" 0
check_eq "clean swap puts the new build in build/" "$(version_of "$ROOT/build")" new
check_test "clean swap consumes build.next/" "clean swap left build.next/ behind" ! -e "$ROOT/build.next"
check_test "clean swap removes the old build" "clean swap left build.old/ behind" ! -e "$ROOT/build.old"
check_test "completion marker does not leak into build/" "completion marker leaked into build/" ! -e "$ROOT/build/.build-complete"

# --- 4. First build: no build/ yet ------------------------------------------
make_tree "$ROOT" no complete
run_swap "$ROOT"
check_eq "first-build swap exits 0" "$RC" 0
check_eq "first-build swap creates build/" "$(version_of "$ROOT/build")" new

# --- 5. The app runs from build/ → deferred ---------------------------------
make_tree "$ROOT" yes complete
make_ps_stub 0 <<EOF
/sbin/launchd
$ROOT/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_swap "$ROOT"
check_eq "running app defers the swap (exit 3)" "$RC" 3
check "deferral names the running process" "$OUT" "$ROOT/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop"
check "deferral tells the owner to run make app-swap" "$OUT" "make app-swap"
check_eq "deferral leaves build/ untouched" "$(version_of "$ROOT/build")" old
check_eq "deferral keeps the staged build" "$(version_of "$ROOT/build.next")" new
check_test "deferral keeps the completion marker" "deferral lost the completion marker" -f "$ROOT/build.next/.build-complete"

# --- 6. ps fails → fail closed ----------------------------------------------
make_tree "$ROOT" yes complete
make_ps_stub 1 <<< "ps: some catastrophe"
run_swap "$ROOT"
check_eq "failing ps exits 1" "$RC" 1
check "failing ps is reported" "$OUT" "ps failed"
check_eq "failing ps leaves build/ untouched" "$(version_of "$ROOT/build")" old

# --- 7. WAIT=1, the owner quits while we wait --------------------------------
make_tree "$ROOT" yes complete
make_ps_stub 0 1 <<EOF
$ROOT/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_swap "$ROOT" WAIT=1 WAIT_TIMEOUT=30
check_eq "WAIT=1 swaps once the app quits" "$RC" 0
check "WAIT=1 asks the owner to quit" "$OUT" "Quit Watchtower"
check_eq "WAIT=1 puts the new build in build/" "$(version_of "$ROOT/build")" new

# --- 8. WAIT=1, the app never quits → timeout --------------------------------
make_tree "$ROOT" yes complete
make_ps_stub 0 <<EOF
$ROOT/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_swap "$ROOT" WAIT=1 WAIT_TIMEOUT=0
check_eq "WAIT=1 timeout exits 1" "$RC" 1
check "WAIT=1 timeout is reported" "$OUT" "timed out"
check_eq "WAIT=1 timeout leaves build/ untouched" "$(version_of "$ROOT/build")" old
check_eq "WAIT=1 timeout keeps the staged build" "$(version_of "$ROOT/build.next")" new

# --- 9. Space and '+' in the project path ------------------------------------
ODD="$WORK_DIR/my feature+x/project"
make_tree "$ODD" yes complete
make_ps_stub 0 <<EOF
$ODD/build/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_swap "$ODD"
check_eq "odd path: running app defers the swap" "$RC" 3
make_ps_stub 0 <<< "$CLEAN_PS"
run_swap "$ODD"
check_eq "odd path: clean swap exits 0" "$RC" 0
check_eq "odd path: new build in build/" "$(version_of "$ODD/build")" new

# --- 10. build-app.sh's finish-staged-build block ----------------------------
SNIPPET="$WORK_DIR/finish.sh"
END_MARKER="# END finish-staged-build"
sed -n "/# BEGIN finish-staged-build/,/$END_MARKER/p" "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'finish_staged_build()' "$SNIPPET"; then
    echo "FAIL: finish-staged-build extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi
if [ "$(tail -n 1 "$SNIPPET")" != "$END_MARKER" ]; then
    echo "FAIL: extracted block does not end at '$END_MARKER' — END marker lost, extraction ran to EOF"
    exit 1
fi

FAKE="$WORK_DIR/finish-root"
mkdir -p "$FAKE/scripts" "$FAKE/build.next"
RUNNER="$WORK_DIR/finish-runner.sh"
cat > "$RUNNER" <<EOF
set -euo pipefail
PROJECT_ROOT="$FAKE"
SCRIPT_DIR="$FAKE/scripts"
BUILD_DIR="$FAKE/build"
STAGE_DIR="$FAKE/build.next"
APP_NAME="Watchtower"
STAGED_BUILD_MARKER=".build-complete"
. "$SNIPPET"
finish_staged_build
echo "OUT_DIR=\$OUT_DIR"
echo "APP_BUNDLE=\$APP_BUNDLE"
print_swap_deferred_banner
EOF

# run_finish <stub-app-swap-exit-code>
run_finish() {
    printf '#!/bin/bash\nexit %s\n' "$1" > "$FAKE/scripts/app-swap.sh"
    chmod +x "$FAKE/scripts/app-swap.sh"
    rm -f "$FAKE/build.next/.build-complete"
    RC=0
    OUT=$(bash "$RUNNER" 2>&1) || RC=$?
}

run_finish 0
check_eq "finish: swapped build exits 0" "$RC" 0
check "finish: swapped build reports build/" "$OUT" "OUT_DIR=$FAKE/build"$'\n'
check "finish: swapped build points APP_BUNDLE at build/" "$OUT" "APP_BUNDLE=$FAKE/build/Watchtower.app"
case "$OUT" in
    *"make app-swap"*) note_fail "finish: swapped build must not print the deferral banner" ;;
    *) echo "ok: finish: swapped build prints no deferral banner" ;;
esac
check_test "finish: marks the staged build complete before the swap" "finish: completion marker not written" -f "$FAKE/build.next/.build-complete"

run_finish 3
check_eq "finish: deferred swap still exits 0" "$RC" 0
check "finish: deferred swap reports the staging dir" "$OUT" "OUT_DIR=$FAKE/build.next"
check "finish: deferred swap ends with the make app-swap banner" "$OUT" "make app-swap"

run_finish 1
check_eq "finish: swap error fails the build" "$RC" 1
check "finish: swap error names where the build is" "$OUT" "the finished build is in $FAKE/build.next"

# --- 11. build-app.sh never writes to build/ itself --------------------------
# Every line naming $BUILD_DIR that is not a comment or a message (an echo with
# no redirection other than >&2) must be on this allowlist;
# anything else would write into build/ during the long part of the build.
# shellcheck disable=SC2016  # the patterns match literal "$VAR" text
UNEXPECTED=$(grep -n 'BUILD_DIR' "$BUILD_APP" \
    | grep -v -E '^[0-9]+:[[:space:]]*#' \
    | grep -v -E '^[0-9]+:[[:space:]]*echo [^>]*(>&2)?$' \
    | grep -v -F 'BUILD_DIR="$PROJECT_ROOT/build"' \
    | grep -v -F 'BUILD_DIR="$DESKTOP_DIR/.build" bash' \
    | grep -v -F 'OUT_DIR="$BUILD_DIR"' || true)
if [ -z "$UNEXPECTED" ]; then
    echo "ok: build-app.sh only touches \$BUILD_DIR through the swap"
else
    note_fail "build-app.sh references \$BUILD_DIR outside the allowlist:"
    printf '%s\n' "$UNEXPECTED"
fi
# shellcheck disable=SC2016  # literal "$STAGE_DIR" text
if grep -q -F 'rm -rf "$STAGE_DIR"' "$BUILD_APP"; then
    echo "ok: build-app.sh cleans the staging dir"
else
    note_fail "build-app.sh no longer cleans \$STAGE_DIR"
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) FAILED"
    exit 1
fi
echo "All app-swap tests passed."
