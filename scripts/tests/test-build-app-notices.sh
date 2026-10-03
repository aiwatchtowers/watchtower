#!/bin/bash
# Tests for the third-party notices the app ships (ruling R18):
#   - scripts/build-app.sh copies THIRD_PARTY_NOTICES.md into the bundle's
#     Contents/Resources;
#   - the notices file names every grammar module the release build compiles
#     in (internal/codeindex/grammar_<id>.go and grammars_min.go), and
#     carries the licence texts the grammars need: the MIT text, the full
#     Apache-2.0 text, the Elixir NOTICE and the MPL-2.0 source pointer.
#
# Reads files only — never builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
BUILD_APP="$ROOT/scripts/build-app.sh"
NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

if grep -qE '^[[:space:]]*cp "\$PROJECT_ROOT/THIRD_PARTY_NOTICES\.md" "\$APP_BUNDLE/Contents/Resources/' "$BUILD_APP"; then
    echo "ok: build-app.sh copies THIRD_PARTY_NOTICES.md into Contents/Resources"
else
    fail "build-app.sh has no step copying THIRD_PARTY_NOTICES.md into \$APP_BUNDLE/Contents/Resources"
fi

modules=$(grep -ohE 'github\.com/alexaandru/go-sitter-forest/[a-z_]+' \
    "$ROOT"/internal/codeindex/grammar_*.go "$ROOT/internal/codeindex/grammars_min.go" | sort -u)
if [ -z "$modules" ]; then
    fail "no grammar modules found in grammar_*.go / grammars_min.go"
fi
for m in $modules; do
    grep -qF "\`$m\`" "$NOTICES" || fail "THIRD_PARTY_NOTICES.md does not list $m"
done
echo "ok: every compiled-in grammar module is listed ($(echo "$modules" | wc -l | tr -d ' '))"

for marker in \
    'Permission is hereby granted, free of charge' \
    'TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION' \
    'Copyright 2021 The Elixir Team' \
    'https://github.com/alaviss/tree-sitter-nim' \
    'COPYRIGHT AND PERMISSION NOTICE (ICU 58 and later)'; do
    grep -qF "$marker" "$NOTICES" || fail "THIRD_PARTY_NOTICES.md lacks: $marker"
done
[ "$rc" -eq 0 ] && echo "ok: licence texts present"
exit $rc
