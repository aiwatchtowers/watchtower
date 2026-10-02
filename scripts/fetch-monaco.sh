#!/bin/bash
# POC (code viewer): downloads the pinned Monaco editor AMD build into
# WatchtowerDesktop/Sources/CodeEditorWeb/vs (gitignored — the vendored build
# is ~15 MB of minified JS, kept out of the public repo). Idempotent: an
# existing copy of the pinned version is left alone.
#
# Trimmed on the way in: the localized message packs (nls/) and the
# TypeScript language-service worker (7 MB) — a view-and-quick-fix editor
# keeps TS/JS syntax highlighting, not IntelliSense.
set -euo pipefail

VERSION="0.57.0"
SHA256="3ea1712fbacd3290cf4751007e3a5b57cc279767607812d4c3e57925fb0b05c2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$(dirname "$SCRIPT_DIR")/WatchtowerDesktop/Sources/CodeEditorWeb/vs"
STAMP="$DEST/.monaco-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ]; then
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching monaco-editor $VERSION..."
curl -fsSL -o "$TMP/monaco.tgz" "https://registry.npmjs.org/monaco-editor/-/monaco-editor-$VERSION.tgz"
echo "$SHA256  $TMP/monaco.tgz" | shasum -a 256 -c - >/dev/null
tar xzf "$TMP/monaco.tgz" -C "$TMP"

rm -rf "$TMP/package/min/vs/nls"
rm -f "$TMP"/package/min/vs/assets/ts.worker-*.js

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$TMP/package/min/vs" "$DEST"
cp "$TMP/package/LICENSE" "$DEST/LICENSE"
echo "$VERSION" > "$STAMP"
echo "    Monaco $VERSION -> $DEST ($(du -sh "$DEST" | cut -f1))"
