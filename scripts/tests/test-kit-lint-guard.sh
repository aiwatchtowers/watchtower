#!/bin/bash
# Tests for scripts/kit-lint-guard.sh — no inline swiftlint:disable of a kit_
# rule (or `all`) under Sources/Views and Sources/App, and under the phone's
# Sources/Features.
#
# Runs the real script against scratch WatchtowerDesktop and WatchtowerMobile
# roots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/../kit-lint-guard.sh"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

bash -n "$GUARD" && echo "ok: bash -n" || note_fail "bash -n kit-lint-guard.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
MOBILE_DIR="$WORK_DIR/mobile"
mkdir -p "$WORK_DIR/Sources/Views" "$WORK_DIR/Sources/App" "$MOBILE_DIR/Sources/Features"

expect() { # expect <pass|fail> <name> <line>
    printf '%s\n' "$3" > "$WORK_DIR/Sources/Views/Probe.swift"
    if bash "$GUARD" "$WORK_DIR" "$MOBILE_DIR" >/dev/null 2>&1; then got=pass; else got=fail; fi
    [ "$got" = "$1" ] && echo "ok: $2" || note_fail "$2 (expected $1, got $got)"
}

expect pass "an ordinary rule may be disabled" '    // swiftlint:disable:next force_unwrapping'
expect pass "no disable at all" '    let x = 1'
expect fail "disable:next of a kit rule" '    // swiftlint:disable:next kit_no_raw_metrics'
expect fail "disable:this of a kit rule" '        .padding(3) // swiftlint:disable:this kit_no_raw_metrics'
expect fail "block disable of a kit rule" '// swiftlint:disable kit_no_form'
expect fail "a kit rule after another rule" '// swiftlint:disable:next trailing_closure kit_no_color_opacity'
expect fail "disable all" '// swiftlint:disable all'
expect fail "disable:previous all" '// swiftlint:disable:previous all'

rm "$WORK_DIR/Sources/Views/Probe.swift"
printf '// swiftlint:disable kit_no_groupbox\n' > "$WORK_DIR/Sources/App/Probe.swift"
if bash "$GUARD" "$WORK_DIR" "$MOBILE_DIR" >/dev/null 2>&1; then note_fail "Sources/App is scanned"; else echo "ok: Sources/App is scanned"; fi

rm "$WORK_DIR/Sources/App/Probe.swift"
printf '    // swiftlint:disable:next kit_no_raw_metrics\n' > "$MOBILE_DIR/Sources/Features/Probe.swift"
if bash "$GUARD" "$WORK_DIR" "$MOBILE_DIR" >/dev/null 2>&1; then note_fail "the phone's Sources/Features is scanned"; else echo "ok: the phone's Sources/Features is scanned"; fi

[ "$FAILURES" -eq 0 ] && echo "PASS" || { echo "$FAILURES failure(s)"; exit 1; }
