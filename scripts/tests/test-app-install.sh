#!/bin/bash
# Tests for scripts/app-install.sh (make app-install).
#
# The script runs for real inside a temp project tree (its PROJECT_ROOT is
# derived from its own location) and installs into a temp INSTALL_DIR, with
# `ps`, `ditto` and `open` stubbed first in PATH and LSREGISTER pointed at a
# stub — nothing touches /Applications, LaunchServices or a running app.
#
# Covers:
#   - no build/Watchtower.app                  → exit 1, "run 'make app'"
#   - a completed staged build not yet swapped → exit 1, "make app-swap"
#   - fresh install (INSTALL_DIR created)      → installed, no temp/old bundle
#     left, lsregister -u build copy and -f installed copy, no relaunch
#   - reinstall while the installed app runs, owner quits while waiting
#                                              → replaced, relaunched with open
#   - installed app never quits                → exit 1 after WAIT_TIMEOUT,
#     old install untouched, temp copy cleaned up, no relaunch
#   - ditto fails                              → exit 1, old install untouched,
#     no half bundle left
#   - lsregister fails                         → warning only, exit 0
#   - ps fails                                 → exit 1, old install untouched
#   - INSTALL_DIR='~/...' (unexpanded tilde)   → resolved against $HOME
#   - INSTALL_DIR with a trailing slash, or relative, while the app runs from
#     it → still detected (canonicalised), nothing replaced on timeout
#   - INSTALL_DIR=build/ itself                → refused
#   - paths with a space and a '+'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/.."

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

# Canonical (pwd -P) like the scripts' own paths: on macOS mktemp lands under
# the /var -> /private/var symlink, and fixtures must name the path ps would.
WORK_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

STUB_DIR="$WORK_DIR/stub"
LOG="$WORK_DIR/calls.log"
mkdir -p "$STUB_DIR"

# make_ps_stub <exit-code> [running-calls] — as in test-app-swap.sh: with
# running-calls=N the fixture is printed only on the first N calls.
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

# ditto <src> <dst>: a plain recursive copy; DITTO_FAIL=1 copies half a bundle
# and fails, like an interrupted copy.
cat > "$STUB_DIR/ditto" <<'EOF'
#!/bin/bash
if [ "${DITTO_FAIL:-}" = "1" ]; then
    mkdir -p "$2"
    echo half > "$2/partial"
    exit 1
fi
cp -R "$1" "$2"
EOF
cat > "$STUB_DIR/open" <<EOF
#!/bin/bash
echo "open \$*" >> "$LOG"
EOF
cat > "$STUB_DIR/lsregister" <<EOF
#!/bin/bash
echo "lsregister \$*" >> "$LOG"
[ "\${LSREGISTER_FAIL:-}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$STUB_DIR/ditto" "$STUB_DIR/open" "$STUB_DIR/lsregister"

# make_tree <root> <build:yes|no> <staged:yes|no>
make_tree() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/scripts/lib"
    cp "$SCRIPTS/app-install.sh" "$root/scripts/"
    cp "$SCRIPTS/lib/app-guard.sh" "$root/scripts/lib/"
    if [ "$2" = yes ]; then
        mkdir -p "$root/build/Watchtower.app/Contents"
        echo new > "$root/build/Watchtower.app/Contents/version"
    fi
    if [ "$3" = yes ]; then
        mkdir -p "$root/build.next/Watchtower.app"
        touch "$root/build.next/.build-complete"
    fi
}

# seed_install <install_dir> — an existing "old" installed copy.
seed_install() {
    rm -rf "$1"
    mkdir -p "$1/Watchtower.app/Contents"
    echo old > "$1/Watchtower.app/Contents/version"
}

version_of() {
    cat "$1/Watchtower.app/Contents/version" 2>/dev/null || echo missing
}

# leftovers <install_dir> — any temp/aside bundle the install left behind.
leftovers() {
    find "$1" -maxdepth 1 -name '.Watchtower.app.*' 2>/dev/null
}

OUT=""
RC=0
# run_install <root> <install_dir> [VAR=value...]
run_install() {
    local root="$1" dir="$2"
    shift 2
    : > "$LOG"
    RC=0
    OUT=$(env PATH="$STUB_DIR:$PATH" LSREGISTER="$STUB_DIR/lsregister" INSTALL_DIR="$dir" "$@" \
        bash "$root/scripts/app-install.sh" 2>&1) || RC=$?
}

CLEAN_PS="/sbin/launchd"
ROOT="$WORK_DIR/project"
DEST_DIR="$WORK_DIR/Applications"
make_ps_stub 0 <<< "$CLEAN_PS"

# --- 1. Nothing built ---------------------------------------------------------
make_tree "$ROOT" no no
run_install "$ROOT" "$DEST_DIR"
check_eq "missing build exits 1" "$RC" 1
check "missing build points at make app" "$OUT" "run 'make app' first"

# --- 2. A staged build waits for its swap ------------------------------------
make_tree "$ROOT" yes yes
run_install "$ROOT" "$DEST_DIR"
check_eq "pending staged build exits 1" "$RC" 1
check "pending staged build points at make app-swap" "$OUT" "make app-swap"
check_eq "pending staged build installs nothing" "$(version_of "$DEST_DIR")" missing

# --- 3. Fresh install ----------------------------------------------------------
make_tree "$ROOT" yes no
rm -rf "$DEST_DIR"
run_install "$ROOT" "$DEST_DIR"
CALLS=$(cat "$LOG")
check_eq "fresh install exits 0" "$RC" 0
check_eq "fresh install copies the bundle" "$(version_of "$DEST_DIR")" new
check_eq "fresh install leaves no temp bundle" "$(leftovers "$DEST_DIR")" ""
check "fresh install unregisters the build/ copy" "$CALLS" "lsregister -u $ROOT/build/Watchtower.app"
check "fresh install registers the installed copy" "$CALLS" "lsregister -f $DEST_DIR/Watchtower.app"
case "$CALLS" in
    *open*) note_fail "fresh install must not launch an app that was not running" ;;
    *) echo "ok: fresh install does not launch the app" ;;
esac

# --- 4. Reinstall while the installed app runs; owner quits ------------------
make_tree "$ROOT" yes no
seed_install "$DEST_DIR"
make_ps_stub 0 2 <<EOF
$DEST_DIR/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_install "$ROOT" "$DEST_DIR" WAIT_TIMEOUT=30
CALLS=$(cat "$LOG")
check_eq "reinstall after quit exits 0" "$RC" 0
check "reinstall asks the owner to quit" "$OUT" "Quit Watchtower"
check_eq "reinstall replaces the installed copy" "$(version_of "$DEST_DIR")" new
check_eq "reinstall leaves no temp/old bundle" "$(leftovers "$DEST_DIR")" ""
check "reinstall relaunches the installed copy" "$CALLS" "open $DEST_DIR/Watchtower.app"

# --- 5. The installed app never quits → timeout -------------------------------
make_tree "$ROOT" yes no
seed_install "$DEST_DIR"
make_ps_stub 0 <<EOF
$DEST_DIR/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_install "$ROOT" "$DEST_DIR" WAIT_TIMEOUT=0
check_eq "timeout exits 1" "$RC" 1
check "timeout is reported" "$OUT" "timed out"
check_eq "timeout leaves the installed copy alone" "$(version_of "$DEST_DIR")" old
check_eq "timeout cleans up the temp copy" "$(leftovers "$DEST_DIR")" ""
case "$(cat "$LOG")" in
    *open*) note_fail "timeout must not relaunch" ;;
    *) echo "ok: timeout does not relaunch" ;;
esac
make_ps_stub 0 <<< "$CLEAN_PS"

# --- 6. ditto fails -------------------------------------------------------------
make_tree "$ROOT" yes no
seed_install "$DEST_DIR"
run_install "$ROOT" "$DEST_DIR" DITTO_FAIL=1
check_eq "failed copy exits non-zero" "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" nonzero
check_eq "failed copy leaves the installed copy alone" "$(version_of "$DEST_DIR")" old
check_eq "failed copy leaves no half bundle" "$(leftovers "$DEST_DIR")" ""

# --- 7. lsregister fails → warning only ----------------------------------------
make_tree "$ROOT" yes no
seed_install "$DEST_DIR"
run_install "$ROOT" "$DEST_DIR" LSREGISTER_FAIL=1
check_eq "lsregister failure still exits 0" "$RC" 0
check "lsregister failure is a warning" "$OUT" "WARNING: lsregister"
check_eq "lsregister failure still installs" "$(version_of "$DEST_DIR")" new

# --- 8. ps fails → fail closed -------------------------------------------------
make_tree "$ROOT" yes no
seed_install "$DEST_DIR"
make_ps_stub 1 <<< "ps: some catastrophe"
run_install "$ROOT" "$DEST_DIR"
check_eq "failing ps exits 1" "$RC" 1
check_eq "failing ps leaves the installed copy alone" "$(version_of "$DEST_DIR")" old
check_eq "failing ps cleans up the temp copy" "$(leftovers "$DEST_DIR")" ""
make_ps_stub 0 <<< "$CLEAN_PS"

# --- 9. Unexpanded '~/...' INSTALL_DIR -----------------------------------------
FAKE_HOME="$WORK_DIR/home"
mkdir -p "$FAKE_HOME"
make_tree "$ROOT" yes no
# shellcheck disable=SC2088  # the literal tilde is the input under test
run_install "$ROOT" "~/Applications" HOME="$FAKE_HOME"
check_eq "tilde INSTALL_DIR exits 0" "$RC" 0
check_eq "tilde INSTALL_DIR resolves against HOME" "$(version_of "$FAKE_HOME/Applications")" new

# --- 9b. Trailing slash / relative INSTALL_DIR must not blind the guard ------
make_ps_stub 0 <<EOF
$DEST_DIR/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
for spelling in "$DEST_DIR/" "$DEST_DIR//" "Applications"; do
    make_tree "$ROOT" yes no
    seed_install "$DEST_DIR"
    RC=0
    OUT=$(cd "$WORK_DIR" && env PATH="$STUB_DIR:$PATH" LSREGISTER="$STUB_DIR/lsregister" \
        INSTALL_DIR="$spelling" WAIT_TIMEOUT=0 bash "$ROOT/scripts/app-install.sh" 2>&1) || RC=$?
    check_eq "INSTALL_DIR='$spelling': running app still blocks" "$RC" 1
    check "INSTALL_DIR='$spelling': waits for the quit" "$OUT" "Quit Watchtower"
    check_eq "INSTALL_DIR='$spelling': installed copy untouched" "$(version_of "$DEST_DIR")" old
done
make_ps_stub 0 <<< "$CLEAN_PS"

# --- 9c. INSTALL_DIR=build/ itself -----------------------------------------------
make_tree "$ROOT" yes no
run_install "$ROOT" "$ROOT/build/"
check_eq "INSTALL_DIR=build/ is refused" "$RC" 1
check "INSTALL_DIR=build/ says why" "$OUT" "INSTALL_DIR is build/ itself"
check_eq "INSTALL_DIR=build/ leaves the build alone" "$(version_of "$ROOT/build")" new

# --- 10. Space and '+' in both paths -------------------------------------------
ODD_ROOT="$WORK_DIR/my feature+x/project"
ODD_DEST="$WORK_DIR/My Apps+"
make_tree "$ODD_ROOT" yes no
seed_install "$ODD_DEST"
make_ps_stub 0 1 <<EOF
$ODD_DEST/Watchtower.app/Contents/MacOS/WatchtowerDesktop
EOF
run_install "$ODD_ROOT" "$ODD_DEST" WAIT_TIMEOUT=30
check_eq "odd paths: install exits 0" "$RC" 0
check_eq "odd paths: installed copy replaced" "$(version_of "$ODD_DEST")" new
check "odd paths: relaunch uses the full path" "$(cat "$LOG")" "open $ODD_DEST/Watchtower.app"

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) FAILED"
    exit 1
fi
echo "All app-install tests passed."
