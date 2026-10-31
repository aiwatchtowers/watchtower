#!/bin/bash
# Tests for the third-party notices the app ships (ruling R18):
#   - scripts/build-app.sh copies THIRD_PARTY_NOTICES.md into the bundle's
#     Contents/Resources;
#   - the notices file names every grammar module the release build compiles
#     in (internal/codeindex/grammar_<id>.go and grammars_min.go), and
#     carries the licence texts the grammars need: the MIT text, the full
#     Apache-2.0 text, the Elixir NOTICE, the MPL-2.0 source pointer and
#     both ICU notices (ICU 58+ and IBM's ICU 1.8.1–57.1);
#   - the SQLite engine section names every tag in internal/sqlcipher/VERSION
#     (mattn, SQLCipher, SQLite) and the GRDB fork's pin from
#     WatchtowerDesktop/Package.swift, and carries the SQLCipher licence;
#   - the "Other Go modules" table lists go-qrcode at the version go.mod
#     requires, with its copyright line.
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
    'COPYRIGHT AND PERMISSION NOTICE (ICU 58 and later)' \
    'Copyright (c) 1995-2016 International Business Machines Corporation and others'; do
    grep -qF "$marker" "$NOTICES" || fail "THIRD_PARTY_NOTICES.md lacks: $marker"
done
[ "$rc" -eq 0 ] && echo "ok: licence texts present"

# The SQLite engine (board #603): VERSION's "<name> <tag>" lines, minus the
# amalgamation hash, each as "<name> <tag>" in the notices.
VERSION_FILE="$ROOT/internal/sqlcipher/VERSION"
engine_tags=$(grep -vE '^[^ ]+ sha256 ' "$VERSION_FILE" || true)
if [ -z "$engine_tags" ]; then
    fail "no tags found in internal/sqlcipher/VERSION"
fi
while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    grep -qF "$tag" "$NOTICES" || fail "THIRD_PARTY_NOTICES.md does not name $tag (internal/sqlcipher/VERSION)"
done <<< "$engine_tags"
grdb_pin=$(sed -n 's|.*aiwatchtowers/GRDB\.swift", exact: "\([^"]*\)".*|\1|p' "$ROOT/WatchtowerDesktop/Package.swift")
if [ -z "$grdb_pin" ]; then
    fail "no aiwatchtowers/GRDB.swift exact pin found in WatchtowerDesktop/Package.swift"
else
    grep -qF "$grdb_pin" "$NOTICES" || fail "THIRD_PARTY_NOTICES.md does not name the GRDB fork pin $grdb_pin"
fi
grep -qF 'Neither the name of the ZETETIC LLC nor the' "$NOTICES" || fail "THIRD_PARTY_NOTICES.md lacks the SQLCipher licence"
[ "$rc" -eq 0 ] && echo "ok: SQLite engine versions and licence present"

# Other Go modules whose notice we carry by owner ruling (go-qrcode: go-hub
# plan 2 Task 6, ask #881): each is listed with the version go.mod requires,
# with its copyright line.
for m in 'github.com/skip2/go-qrcode|Copyright (c) 2014 Tom Harwood'; do
    mod=${m%%|*}
    copyright=${m#*|}
    ver=$(awk -v mod="$mod" '$1 == mod { print $2 } $1 == "require" && $2 == mod { print $3 }' "$ROOT/go.mod" | head -n 1)
    if [ -z "$ver" ]; then
        fail "go.mod does not require $mod"
        continue
    fi
    grep -qE "^\| [^|]+ \| \`${mod//./\\.}\` \| ${ver//./\\.} \| MIT \|" "$NOTICES" \
        || fail "THIRD_PARTY_NOTICES.md does not list $mod at $ver (go.mod) under Other Go modules"
    grep -qF "$copyright" "$NOTICES" || fail "THIRD_PARTY_NOTICES.md lacks $mod's copyright line: $copyright"
done
[ "$rc" -eq 0 ] && echo "ok: other Go modules listed at their go.mod versions"
exit $rc
