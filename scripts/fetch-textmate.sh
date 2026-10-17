#!/bin/bash
# Code viewer (board #738): downloads the pinned TextMate tokenizer
# (vscode-textmate), its regex engine (vscode-oniguruma, a WebAssembly build
# of Oniguruma) and the grammars the editor highlights with (tm-grammars,
# shiki's collection of VS Code and community grammars) into
# WatchtowerDesktop/Sources/CodeEditorWeb/textmate — gitignored, like the
# Monaco build next to it. Idempotent: a copy of the same pins and grammar
# list is left alone. Run by scripts/fetch-monaco.sh.
#
# Repackaged on the way in, for the page's CSP (scripts from the bundle
# only, no fetch): each grammar's JSON becomes an AMD module
# (`define(<json>);`, minified with python3) and onig.wasm a module
# returning it as base64.
#
# GRAMMARS must list every grammar CodeEditorWeb/textmate.js names (a
# language's own and the ones it embeds that the editor should colour);
# CodeEditorPageProtocolTests checks the two lists agree. Only grammars
# whose licence the tm-grammars NOTICE or THIRD_PARTY_NOTICES.md carries
# are listed.
set -euo pipefail

TEXTMATE_VERSION="9.3.2"
TEXTMATE_SHA256="f7c742b16d59600d77529b7a904af09b59dfddb0f046fc045340004ae2fc50e7"
ONIGURUMA_VERSION="2.0.1"
ONIGURUMA_SHA256="3b42911fd9609f2cc3b9c6dd52236b3da73780e633aa7dc381267006b7e7da21"
GRAMMARS_VERSION="1.32.22"
GRAMMARS_SHA256="6d75b2699fe65499bfb81d7e002d79116f2e9d56c417d3fcdd128c239db9e1b1"

GRAMMARS="
bat bicep c clojure coffee cpp cpp-macro csharp css cypher dart diff docker
fsharp go graphql handlebars hcl html html-derivative ini java javascript json jsonc julia
kotlin less liquid lua make markdown mdx mipsasm objective-c pascal perl php powerquery
powershell proto pug python r razor regexp rst ruby rust scala scheme scss shellscript
shellsession solidity sql swift system-verilog tsx twig typescript typespec vb
verilog wgsl xml xsl yaml
"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$(dirname "$SCRIPT_DIR")/WatchtowerDesktop/Sources/CodeEditorWeb/textmate"
STAMP="$DEST/.textmate-version"
WANT="vscode-textmate@$TEXTMATE_VERSION vscode-oniguruma@$ONIGURUMA_VERSION tm-grammars@$GRAMMARS_VERSION $(echo $GRAMMARS)"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch <package> <version> <sha256>: the npm tarball, checked and unpacked
# into $TMP/<package>.
fetch() {
    echo "==> Fetching $1 $2..."
    curl -fsSL -o "$TMP/$1.tgz" "https://registry.npmjs.org/$1/-/$1-$2.tgz"
    echo "$3  $TMP/$1.tgz" | shasum -a 256 -c - >/dev/null
    mkdir -p "$TMP/$1"
    tar xzf "$TMP/$1.tgz" -C "$TMP/$1"
}
fetch vscode-textmate "$TEXTMATE_VERSION" "$TEXTMATE_SHA256"
fetch vscode-oniguruma "$ONIGURUMA_VERSION" "$ONIGURUMA_SHA256"
fetch tm-grammars "$GRAMMARS_VERSION" "$GRAMMARS_SHA256"

OUT="$TMP/out"
mkdir -p "$OUT/grammars"
cp "$TMP/vscode-textmate/package/release/main.js" "$OUT/vscode-textmate.js"
cp "$TMP/vscode-oniguruma/package/release/main.js" "$OUT/vscode-oniguruma.js"
{
    printf 'define(function () { return "'
    base64 -i "$TMP/vscode-oniguruma/package/release/onig.wasm" | tr -d '\n'
    printf '"; });\n'
} > "$OUT/onig-wasm.js"
for name in $GRAMMARS; do
    src="$TMP/tm-grammars/package/grammars/$name.json"
    if [ ! -f "$src" ]; then
        echo "tm-grammars $GRAMMARS_VERSION has no grammar \"$name\"" >&2
        exit 1
    fi
    # Minified on the way: the published JSON is pretty-printed (half the
    # bytes are indentation).
    { printf 'define('; python3 -I -c 'import json, sys; json.dump(json.load(open(sys.argv[1])), sys.stdout, separators=(",", ":"))' "$src"; printf ');\n'; } > "$OUT/grammars/$name.js"
done
cp "$TMP/vscode-textmate/package/LICENSE.md" "$OUT/vscode-textmate.LICENSE.md"
cp "$TMP/vscode-oniguruma/package/LICENSE.txt" "$OUT/vscode-oniguruma.LICENSE.txt"
cp "$TMP/vscode-oniguruma/package/NOTICES.txt" "$OUT/vscode-oniguruma.NOTICES.txt"
cp "$TMP/tm-grammars/package/LICENSE" "$OUT/tm-grammars.LICENSE"
cp "$TMP/tm-grammars/package/NOTICE" "$OUT/tm-grammars.NOTICE"

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$OUT" "$DEST"
echo "$WANT" > "$STAMP"
echo "    TextMate grammars -> $DEST ($(du -sh "$DEST" | cut -f1))"
