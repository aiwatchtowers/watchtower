#!/bin/bash
# Tests for scripts/build-app.sh: the Go CLI it ships is built with
# -tags codegrammars, so the release binary carries the code index's full
# grammar set (an untagged build parses only Go, Swift and Python).
#
# Reads the script only — never builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$SCRIPT_DIR/../build-app.sh"

builds=$(grep -E '^[[:space:]]*([A-Z_]+=[^ ]+ )*go build' "$BUILD_APP" || true)
if [ -z "$builds" ]; then
    echo "FAIL: no go build line found in build-app.sh" >&2
    exit 1
fi
rc=0
while IFS= read -r line; do
    case "$line" in
        *"-tags codegrammars"*) echo "ok: $line" ;;
        *) echo "FAIL: go build without -tags codegrammars: $line" >&2; rc=1 ;;
    esac
done <<< "$builds"
exit $rc
