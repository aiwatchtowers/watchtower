#!/bin/bash
# Manual check of the Files pane's editor page: drives
# WatchtowerDesktop/Sources/CodeEditorWeb/index.html in a headless WKWebView
# the way the Desktop's MonacoEditorView does (show / reload replace|force|
# rebase / rename / close / takePending, edit revisions, reveal, go to
# definition, usages and the cursor stream, Monaco's keybindings for the app's
# navigation chords) and spot-checks the file associations and Monarch
# grammars of languages.js. Not part of any gate; run it after touching
# CodeEditorWeb/ or bumping Monaco.
#
# Needs the Monaco build: scripts/fetch-monaco.sh. Loads local files only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB="$(dirname "$SCRIPT_DIR")/WatchtowerDesktop/Sources/CodeEditorWeb"

if [ ! -f "$WEB/vs/loader.js" ]; then
    echo "Monaco is not installed in WatchtowerDesktop/Sources/CodeEditorWeb/vs." >&2
    echo "Run scripts/fetch-monaco.sh first." >&2
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Compiling the harness..."
xcrun swiftc -swift-version 5 -o "$TMP/editor-bridge-check" "$SCRIPT_DIR/editor-bridge-check.swift"

echo "==> Running against CodeEditorWeb/index.html"
"$TMP/editor-bridge-check" "$WEB"
