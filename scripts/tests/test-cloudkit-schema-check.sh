#!/bin/bash
# Tests for scripts/cloudkit-schema-check.sh (make cloudkit-check).
#
# `xcrun` is stubbed first in PATH: it serves fixture schemas per
# --environment (or fails like cktool without a token), so nothing reaches
# CloudKit.
#
# Covers:
#   - Production equal to Development          → exit 0
#   - Production missing a record type          → exit 1, the type's fields named
#   - Production missing one field              → exit 1, only that field named
#   - field differing only in index flags       → exit 1
#   - grants and whitespace differences ignored → exit 0
#   - no management token                       → exit 1, save-token hint
#   - team id read from Signing.xcconfig        → passed to cktool
#   - no team id anywhere                       → exit 1
#   - an E2E record type missing from both      → exit 1, the type named
#   - a leftover pre-E2E type only in Production → exit 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../cloudkit-schema-check.sh"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
check() { case "$2" in *"$3"*) ;; *) note_fail "$1: missing '$3' in: $2" ;; esac; }
check_not() { case "$2" in *"$3"*) note_fail "$1: unexpected '$3' in: $2" ;; *) ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/xcrun" <<'EOF'
#!/bin/bash
# xcrun cktool export-schema ... --environment E --output-file F
echo "$*" >>"$STUB_DIR/calls"
[ -n "${STUB_NO_TOKEN:-}" ] && { echo "Error: No management token found in arguments"; exit 1; }
env=""; out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --environment) env="$2"; shift ;;
        --output-file) out="$2"; shift ;;
    esac
    shift
done
cp "$STUB_DIR/$env.ckdb" "$out"
EOF
chmod +x "$TMP/bin/xcrun"

DEV='DEFINE SCHEMA

    RECORD TYPE Users (
        "___createTime" TIMESTAMP,
        roles           LIST<INT64>,
        GRANT WRITE TO "_creator",
        GRANT READ TO "_world"
    );

    RECORD TYPE WatchtowerEnvelope (
        "___createTime" TIMESTAMP,
        kind            STRING QUERYABLE SEARCHABLE SORTABLE,
        payload         ENCRYPTED BYTES,
        GRANT WRITE TO "_creator",
        GRANT READ TO "_world"
    );

    RECORD TYPE WatchtowerSignal (
        "___createTime" TIMESTAMP,
        hub             STRING QUERYABLE,
        GRANT WRITE TO "_creator",
        GRANT READ TO "_world"
    );'

# run <prod schema> [env...] → sets OUT and RC
run() {
    local prod="$1"; shift
    rm -f "$TMP/calls"
    printf '%s\n' "$DEV" >"$TMP/development.ckdb"
    printf '%s\n' "$prod" >"$TMP/production.ckdb"
    set +e
    OUT="$(env PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" CLOUDKIT_TEAM_ID=TEAM123 "$@" bash "$SCRIPT" 2>&1)"
    RC=$?
    set -e
}

run "$DEV"
[ "$RC" = 0 ] || note_fail "equal schemas: exit $RC: $OUT"
check "equal schemas" "$OUT" "Production holds everything"
check "team id passed" "$(cat "$TMP/calls")" "--team-id TEAM123"

run 'DEFINE SCHEMA

    RECORD TYPE Users (
        "___createTime" TIMESTAMP,
        roles           LIST<INT64>,
        GRANT WRITE TO "_creator",
        GRANT READ TO "_world"
    );'
[ "$RC" = 1 ] || note_fail "missing type: exit $RC"
check "missing type" "$OUT" "WatchtowerEnvelope kind STRING QUERYABLE SEARCHABLE SORTABLE"
check "missing type" "$OUT" "WatchtowerEnvelope payload ENCRYPTED BYTES"
check "missing type" "$OUT" "Deploy Schema Changes"
check_not "missing type" "$OUT" "Users roles"

run "${DEV/        payload         ENCRYPTED BYTES,
/}"
[ "$RC" = 1 ] || note_fail "missing field: exit $RC"
check "missing field" "$OUT" "WatchtowerEnvelope payload ENCRYPTED BYTES"
check_not "missing field" "$OUT" "WatchtowerEnvelope kind"

run "${DEV/QUERYABLE SEARCHABLE SORTABLE/QUERYABLE}"
[ "$RC" = 1 ] || note_fail "index flags: exit $RC"
check "index flags" "$OUT" "WatchtowerEnvelope kind STRING QUERYABLE SEARCHABLE SORTABLE"

run "$(printf '%s\n' "$DEV" | grep -v 'GRANT READ' | sed 's/  */ /g')"
[ "$RC" = 0 ] || note_fail "grants/whitespace: exit $RC: $OUT"

# Neither environment has the signal type yet (no E2E build ran in Development): the diff alone would pass.
NO_SIGNAL="$(printf '%s\n' "$DEV" | awk '/RECORD TYPE WatchtowerSignal/ { skip = 1 } !skip { print } /\);/ { skip = 0 }')"
rm -f "$TMP/calls"
printf '%s\n' "$NO_SIGNAL" >"$TMP/development.ckdb"
printf '%s\n' "$NO_SIGNAL" >"$TMP/production.ckdb"
set +e
OUT="$(env PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" CLOUDKIT_TEAM_ID=TEAM123 bash "$SCRIPT" 2>&1)"
RC=$?
set -e
[ "$RC" = 1 ] || note_fail "required type: exit $RC: $OUT"
check "required type" "$OUT" "WatchtowerSignal"
check_not "required type" "$OUT" "Production holds everything"

# Production keeps the pre-E2E type the hard cut left behind: harmless.
run "$DEV
    RECORD TYPE WatchtowerRecord (
        payload         ENCRYPTED BYTES
    );"
[ "$RC" = 0 ] || note_fail "leftover type: exit $RC: $OUT"

run "$DEV" STUB_NO_TOKEN=1
[ "$RC" = 1 ] || note_fail "no token: exit $RC"
check "no token" "$OUT" "xcrun cktool save-token --type management"

# Team id from Signing.xcconfig: run a copy of the script inside a temp tree.
mkdir -p "$TMP/tree/scripts" "$TMP/tree/WatchtowerMobile"
cp "$SCRIPT" "$TMP/tree/scripts/"
printf 'DEVELOPMENT_TEAM = XCTEAM9\n' >"$TMP/tree/WatchtowerMobile/Signing.xcconfig"
rm -f "$TMP/calls"
set +e
OUT="$(env -u CLOUDKIT_TEAM_ID PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" bash "$TMP/tree/scripts/cloudkit-schema-check.sh" 2>&1)"
RC=$?
set -e
[ "$RC" = 0 ] || note_fail "xcconfig team: exit $RC: $OUT"
check "xcconfig team" "$(cat "$TMP/calls")" "--team-id XCTEAM9"

rm "$TMP/tree/WatchtowerMobile/Signing.xcconfig"
set +e
OUT="$(env -u CLOUDKIT_TEAM_ID PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" bash "$TMP/tree/scripts/cloudkit-schema-check.sh" 2>&1)"
RC=$?
set -e
[ "$RC" = 1 ] || note_fail "no team: exit $RC"
check "no team" "$OUT" "no team id"

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "PASS: cloudkit-schema-check"
