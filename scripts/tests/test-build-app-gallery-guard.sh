#!/bin/bash
# Tests for the design gallery bundle guard (`check_no_gallery` and
# `check_app_target_deps` in build-app.sh, BEGIN/END gallery-bundle-guard).
#
# Extracts the block verbatim and runs it against synthetic app bundles — no
# `make app`. The symbol cases use the debug binaries of WatchtowerDesktop/.build
# (`swift build` in WatchtowerDesktop/); when one is absent its cases are
# skipped, said aloud, never passed silently.
#
# Covers:
#   - clean bundle, app binary = debug WatchtowerDesktop, control = debug
#     DesignGallery                                   → passes
#   - a planted DesignGallery* file                    → fails
#   - a planted X_DesignKitCatalog.bundle              → fails
#   - app binary = the debug DesignGallery binary      → fails
#   - control binary without gallery symbols           → fails (stale pattern)
#   - no control binary                                → passes with a warning
#   - nm failing on the app binary                     → fails (fail closed)
#   - dump-package: app target clean / depending on DesignKitCatalog /
#     target missing                                   → pass / fail / fail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"
DEBUG_DIR="$SCRIPT_DIR/../../WatchtowerDesktop/.build/debug"

FAILURES=0

note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SNIPPET="$WORK_DIR/snippet.sh"
END_MARKER="# END gallery-bundle-guard"
sed -n "/# BEGIN gallery-bundle-guard/,/$END_MARKER/p" "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'check_no_gallery()' "$SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi
if [ "$(tail -n 1 "$SNIPPET")" != "$END_MARKER" ]; then
    echo "FAIL: extracted block does not end at '$END_MARKER' — END marker lost, extraction ran to EOF"
    exit 1
fi

# make_bundle <name> <app-binary> — a minimal .app with the given executable.
make_bundle() {
    local b="$WORK_DIR/$1.app"
    mkdir -p "$b/Contents/MacOS" "$b/Contents/Resources/WatchtowerDesktop_WatchtowerDesktop.bundle"
    cp "$2" "$b/Contents/MacOS/WatchtowerDesktop"
    echo "$b"
}

# run_guard <expect pass|fail> <label> <bundle> [<control>] [<PATH prefix>]
run_guard() {
    local expect="$1" label="$2" bundle="$3" control="${4:-}" pathpre="${5:-}" rc=0
    PATH="${pathpre:+$pathpre:}$PATH" bash -c '. "$1"; check_no_gallery "$2" "$3"' _ \
        "$SNIPPET" "$bundle" "$control" > "$WORK_DIR/out.txt" 2>&1 || rc=$?
    if { [ "$expect" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
        echo "ok: $label"
    else
        note_fail "$label (expected $expect, rc=$rc): $(cat "$WORK_DIR/out.txt")"
    fi
}

# A tiny binary without gallery symbols for the file-name cases.
PLAIN_BIN="$WORK_DIR/plain"
cp /usr/bin/true "$PLAIN_BIN"

clean=$(make_bundle clean "$PLAIN_BIN")
run_guard pass "clean bundle, no control (warns)" "$clean"
if ! grep -q 'WARNING: no gallery binary' "$WORK_DIR/out.txt"; then
    note_fail "missing control binary was not reported"
fi

planted=$(make_bundle planted "$PLAIN_BIN")
touch "$planted/Contents/Resources/DesignGallery"
run_guard fail "planted DesignGallery* file" "$planted"

catalog=$(make_bundle catalog "$PLAIN_BIN")
mkdir -p "$catalog/Contents/Resources/X_DesignKitCatalog.bundle"
run_guard fail "planted X_DesignKitCatalog.bundle" "$catalog"

# nm failing on the app binary: a stub nm that always errors.
STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"
printf '#!/bin/bash\necho "nm: boom" >&2\nexit 1\n' > "$STUB_DIR/nm"
chmod +x "$STUB_DIR/nm"
run_guard fail "nm failing fails closed" "$clean" "" "$STUB_DIR"

GALLERY_BIN="$DEBUG_DIR/DesignGallery"
APP_BIN="$DEBUG_DIR/WatchtowerDesktop"
if [ -f "$GALLERY_BIN" ] && [ -f "$APP_BIN" ]; then
    real=$(make_bundle real "$APP_BIN")
    run_guard pass "debug WatchtowerDesktop with the gallery control" "$real" "$GALLERY_BIN"
    leaked=$(make_bundle leaked "$GALLERY_BIN")
    run_guard fail "app binary = the debug DesignGallery" "$leaked" "$GALLERY_BIN"
    run_guard fail "control without gallery symbols (stale pattern)" "$clean" "$PLAIN_BIN"
else
    echo "SKIP: symbol cases — no debug DesignGallery/WatchtowerDesktop in $DEBUG_DIR (run swift build in WatchtowerDesktop/)"
fi

# check_app_target_deps over dump-package fixtures.
run_deps() {
    local expect="$1" label="$2" json="$3" rc=0
    printf '%s' "$json" | bash -c '. "$1"; check_app_target_deps' _ "$SNIPPET" \
        > "$WORK_DIR/out.txt" 2>&1 || rc=$?
    if { [ "$expect" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
        echo "ok: $label"
    else
        note_fail "$label (expected $expect, rc=$rc): $(cat "$WORK_DIR/out.txt")"
    fi
}
run_deps pass "app target without gallery deps" \
    '{"targets":[{"name":"WatchtowerDesktop","dependencies":[{"byName":["DesignKit",null]},{"product":["GRDB","GRDB.swift",null,null]}]}]}'
run_deps fail "app target depending on DesignKitCatalog" \
    '{"targets":[{"name":"WatchtowerDesktop","dependencies":[{"byName":["DesignKit",null]},{"target":["DesignKitCatalog",null]}]}]}'
run_deps fail "app target missing" \
    '{"targets":[{"name":"DesignKit","dependencies":[]}]}'

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all gallery guard tests passed"
