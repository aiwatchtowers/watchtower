#!/bin/bash
# Tests for the signing-identity-selection block of scripts/build-app.sh.
#
# Extracts the block verbatim (BEGIN/END markers) and runs it in a subshell
# against a stubbed `security` binary — no real keychain, no codesign, no app
# build (`make app` stays out of automated verification by design).
#
# Covers:
#   - single Developer ID identity          → auto-detected
#   - SAME identity duplicated across keychains (login + System) → still
#     auto-detected (sort -u; the line-count regression that silently fell
#     back to ad-hoc)
#   - two DISTINCT identities               → ad-hoc, "ambiguous" reason
#   - zero identities (valid, degenerate)   → ad-hoc, "no ... identity" reason
#   - security lookup failure               → ad-hoc, "lookup failed" reason;
#     hard error on release when CODESIGN_IDENTITY is set
#   - explicit CODESIGN_IDENTITY found      → used verbatim
#   - explicit set-but-missing              → release: hard exit 1 (never a
#     substitute cert); dev: warn + auto-detect fallback
#   - --timestamp=none only on the dev path
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
sed -n '/# BEGIN signing-identity-selection/,/# END signing-identity-selection/p' "$BUILD_APP" > "$SNIPPET"
if ! grep -q 'FIND_IDENTITY_OUTPUT' "$SNIPPET"; then
    echo "FAIL: snippet extraction came up empty — markers moved in build-app.sh?"
    exit 1
fi

STUB_DIR="$WORK_DIR/stub"
mkdir -p "$STUB_DIR"

# make_stub <exit-code>  — fixture text on stdin becomes the stub's output.
make_stub() {
    cat > "$STUB_DIR/fixture.txt"
    cat > "$STUB_DIR/security" <<EOF
#!/bin/bash
cat "$STUB_DIR/fixture.txt"
exit $1
EOF
    chmod +x "$STUB_DIR/security"
}

# run_case <dev_mode true|false> <codesign_identity or empty>
# Prints RESULT=/REASON=/TIMESTAMP= lines on success; propagates the snippet's
# exit code. Runs in a subshell with the stubbed `security` first in PATH.
run_case() {
    (
        PATH="$STUB_DIR:$PATH"
        DEV_MODE="$1"
        CODESIGN_IDENTITY="$2"
        set -euo pipefail
        # shellcheck disable=SC1090
        . "$SNIPPET"
        printf 'RESULT=%s\nREASON=%s\nTIMESTAMP=%s\n' \
            "$SIGN_IDENTITY" "$ADHOC_REASON" "$TIMESTAMP_FLAG"
    )
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

IDENTITY='Developer ID Application: Vadym Trunov (7WFLZDVUV3)'
OTHER_IDENTITY='Developer ID Application: Other Corp (ABCDE12345)'

# --- 1. Single identity → auto-detected -------------------------------------
make_stub 0 <<EOF
  1) 0123456789ABCDEF "$IDENTITY"
     1 valid identities found
EOF
OUT=$(run_case false "")
check "single identity auto-detected" "$OUT" "RESULT=$IDENTITY"
case "$OUT" in
    *'TIMESTAMP=--timestamp'*) note_fail "release build keeps trusted timestamp (found --timestamp flag)" ;;
    *) echo "ok: release build keeps trusted timestamp" ;;
esac

# --- 2. Same identity in login + System keychains (the reviewed major) ------
make_stub 0 <<EOF
  1) 0123456789ABCDEF "$IDENTITY"
  2) 0123456789ABCDEF "$IDENTITY"
     2 valid identities found
EOF
OUT=$(run_case false "")
check "duplicate lines collapse to one identity (sort -u)" "$OUT" "RESULT=$IDENTITY"

# --- 3. Two distinct identities → ad-hoc with an 'ambiguous' reason ---------
make_stub 0 <<EOF
  1) 0123456789ABCDEF "$IDENTITY"
  2) FEDCBA9876543210 "$OTHER_IDENTITY"
     2 valid identities found
EOF
OUT=$(run_case false "")
check "two distinct identities fall back to ad-hoc" "$OUT" 'RESULT=-'
check "ambiguous reason names the count" "$OUT" '2 distinct'
check "ambiguous reason advises CODESIGN_IDENTITY" "$OUT" 'Set CODESIGN_IDENTITY'

# --- 4. Zero identities (valid, degenerate output) → ad-hoc -----------------
make_stub 0 <<EOF
     0 valid identities found
EOF
OUT=$(run_case false "")
check "no identities fall back to ad-hoc" "$OUT" 'RESULT=-'
check "none-found reason says no identity found" "$OUT" 'no "Developer ID Application" identity found'

# --- 5. security lookup failure ---------------------------------------------
make_stub 44 <<EOF
security: SecKeychainSearchCopyNext: The specified keychain could not be found.
EOF
OUT=$(run_case true "")
check "lookup failure (dev, no explicit) falls back to ad-hoc" "$OUT" 'RESULT=-'
check "lookup-failure reason carries the exit code" "$OUT" 'security find-identity exit 44'
check "lookup-failure reason carries security's stderr" "$OUT" 'keychain could not be found'

RC=0
OUT=$(run_case false "$IDENTITY" 2>&1) || RC=$?
if [ "$RC" -ne 0 ]; then
    echo "ok: lookup failure + explicit identity on release exits non-zero"
else
    note_fail "lookup failure + explicit identity on release exits non-zero (got rc=0)"
fi
check "lookup-failure release error mentions the lookup" "$OUT" 'keychain lookup failed'

# --- 6. Explicit CODESIGN_IDENTITY found → used verbatim --------------------
make_stub 0 <<EOF
  1) 0123456789ABCDEF "$IDENTITY"
  2) FEDCBA9876543210 "$OTHER_IDENTITY"
     2 valid identities found
EOF
OUT=$(run_case false "$IDENTITY")
check "explicit identity wins over ambiguity" "$OUT" "RESULT=$IDENTITY"

# --- 7. Explicit set-but-missing --------------------------------------------
make_stub 0 <<EOF
  1) 0123456789ABCDEF "$IDENTITY"
     1 valid identities found
EOF
RC=0
OUT=$(run_case false "Developer ID Application: Nobody (MISSING123)" 2>&1) || RC=$?
if [ "$RC" -ne 0 ]; then
    echo "ok: explicit-but-missing identity hard-fails the release build"
else
    note_fail "explicit-but-missing identity hard-fails the release build (got rc=0)"
fi
check "release hard-fail refuses substitution" "$OUT" 'refusing to substitute'

OUT=$(run_case true "Developer ID Application: Nobody (MISSING123)")
check "dev build falls back to auto-detect on missing explicit identity" "$OUT" "RESULT=$IDENTITY"
check "dev fallback warns about the missing identity" "$OUT" 'not found in keychain'

# --- 8. Timestamp flag: dev only --------------------------------------------
OUT=$(run_case true "")
check "dev build sets --timestamp=none" "$OUT" 'TIMESTAMP=--timestamp=none'

echo ""
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES test(s) FAILED"
    exit 1
fi
echo "All signing-selection tests passed."
