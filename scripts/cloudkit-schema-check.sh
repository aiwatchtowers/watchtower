#!/bin/bash
# Checks that the CloudKit Production schema holds everything the Development
# schema does (make cloudkit-check; run before every mobile-testflight upload).
#
# Development grows its schema on its own as builds save records; Production
# never does, and only the CloudKit Console's "Deploy Schema Changes" moves
# the schema there (cktool's import-schema refuses Production: "endpoint not
# applicable in the environment 'production'"). A TestFlight phone and a
# Developer ID Mac both run on Production, so a missing record type or field
# there fails their saves with no error on screen. This script fails instead,
# naming what is missing. It also fails when Production lacks a record type the
# current build writes (REQUIRED_TYPES: the E2E hard cut's sealed envelope and
# signal, mobile E2E spec §2.8), even when Development lacks it too: run a
# Development build of the Mac hub first so Development defines it, then deploy.
#
# Needs a CloudKit management token saved once in an interactive terminal:
#   xcrun cktool save-token --type management
# The team comes from CLOUDKIT_TEAM_ID, else DEVELOPMENT_TEAM in the
# gitignored WatchtowerMobile/Signing.xcconfig.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER_ID="${CLOUDKIT_CONTAINER_ID:-iCloud.com.aiwatchtowers.watchtower}"
CONSOLE_URL="https://icloud.developer.apple.com/dashboard/"
REQUIRED_TYPES="WatchtowerEnvelope WatchtowerSignal"

TEAM_ID="${CLOUDKIT_TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -f "$PROJECT_ROOT/WatchtowerMobile/Signing.xcconfig" ]; then
    TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' \
        "$PROJECT_ROOT/WatchtowerMobile/Signing.xcconfig" | head -1)"
fi
if [ -z "$TEAM_ID" ]; then
    echo "error: no team id: set CLOUDKIT_TEAM_ID or DEVELOPMENT_TEAM in WatchtowerMobile/Signing.xcconfig" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export_schema() {
    local env="$1"
    if ! xcrun cktool export-schema --team-id "$TEAM_ID" --container-id "$CONTAINER_ID" \
        --environment "$env" --output-file "$WORK/$env.ckdb" >"$WORK/$env.log" 2>&1; then
        echo "error: could not read the $env schema of $CONTAINER_ID:" >&2
        sed 's/^/  /' "$WORK/$env.log" >&2
        if grep -q "management token" "$WORK/$env.log"; then
            echo "  Save a token once, in Terminal.app: xcrun cktool save-token --type management" >&2
        fi
        exit 1
    fi
}

# One line per field: "<record type> <field definition>", grants and the
# DEFINE SCHEMA header dropped, whitespace collapsed. A field whose type or
# index flags differ counts as missing, as Production would refuse it too.
flatten() {
    awk '
        /RECORD TYPE/ {
            name = $0
            sub(/^[[:space:]]*RECORD TYPE[[:space:]]*/, "", name)
            sub(/[[:space:]]*\($/, "", name)
            next
        }
        /^[[:space:]]*\);/ { name = ""; next }
        name != "" && !/^[[:space:]]*GRANT / && NF {
            line = $0
            gsub(/[[:space:]]+/, " ", line)
            sub(/^ /, "", line)
            sub(/,$/, "", line)
            print name " " line
        }
    ' "$1" | sort -u
}

export_schema development
export_schema production

flatten "$WORK/development.ckdb" >"$WORK/dev.txt"
flatten "$WORK/production.ckdb" >"$WORK/prod.txt"
MISSING="$(comm -23 "$WORK/dev.txt" "$WORK/prod.txt")"
for type in $REQUIRED_TYPES; do
    if ! grep -q "^$type " "$WORK/prod.txt"; then
        MISSING="${MISSING:+$MISSING
}$type (record type; Development needs it first: run a Development build of the Mac hub)"
    fi
done

if [ -n "$MISSING" ]; then
    echo "error: CloudKit Production lacks schema that Development has:" >&2
    printf '%s\n' "$MISSING" | sed 's/^/  /' >&2
    echo "Deploy it: $CONSOLE_URL -> CloudKit Database -> $CONTAINER_ID -> Deploy Schema Changes." >&2
    echo "Skip once with SKIP_CLOUDKIT_CHECK=1." >&2
    exit 1
fi
echo "CloudKit schema: Production holds everything Development has."
