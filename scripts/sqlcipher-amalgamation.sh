#!/bin/bash
# Regenerates internal/sqlcipher's SQLite amalgamation from a SQLCipher
# community release tag (board #603).
#
#   scripts/sqlcipher-amalgamation.sh v4.19.0
#
# Clones github.com/sqlcipher/sqlcipher at the tag into a temp dir, builds
# the amalgamation from source (`make sqlite3.c` needs tclsh, which macOS
# ships), and writes:
#   internal/sqlcipher/sqlite3-binding.c   sqlite3.c
#   internal/sqlcipher/sqlite3-binding.h   sqlite3.h
#   internal/sqlcipher/sqlite3ext.h        src/sqlite3ext.h
# each wrapped in mattn's `#ifndef USE_LIBSQLITE3` guard, and
# internal/sqlcipher/VERSION (mattn tag, SQLCipher tag, SQLite version and
# the amalgamation's SHA-256). It never downloads a prebuilt binary.
#
# An upgrade moves in lockstep with the Swift side (SQLCipher.swift pinned to
# the same tag in the GRDB fork); the Go<->Swift interop test is the gate.
set -euo pipefail

if [ $# -ne 1 ]; then
	echo "usage: $0 <sqlcipher-tag, e.g. v4.19.0>" >&2
	exit 2
fi
TAG="$1"
MATTN_TAG="v1.14.52"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/internal/sqlcipher"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v tclsh >/dev/null || { echo "tclsh is required (make sqlite3.c runs Tcl)" >&2; exit 1; }

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
	https://github.com/sqlcipher/sqlcipher.git "$WORK/src"
(
	cd "$WORK/src"
	./configure --with-tempstore=yes --disable-tcl >"$WORK/configure.log" 2>&1
	make sqlite3.c >"$WORK/make.log" 2>&1
)

# wrap SRC DST: mattn's guard, so a libsqlite3 build would see an empty file.
wrap() {
	{
		printf '#ifndef USE_LIBSQLITE3\n'
		cat "$1"
		printf '#else // USE_LIBSQLITE3\n // If users really want to link against the system sqlite3 we\n// need to make this file a noop.\n #endif'
	} >"$2"
}
wrap "$WORK/src/sqlite3.c" "$DEST/sqlite3-binding.c"
wrap "$WORK/src/sqlite3.h" "$DEST/sqlite3-binding.h"
wrap "$WORK/src/src/sqlite3ext.h" "$DEST/sqlite3ext.h"
# The amalgamation includes "sqlite3.h"; mattn's sources name the header
# sqlite3-binding.h, so the include is renamed as mattn's upgrade tool does.
sed -i.bak 's/^#include "sqlite3.h"/#include "sqlite3-binding.h"/' "$DEST/sqlite3-binding.c" "$DEST/sqlite3ext.h"
rm -f "$DEST/sqlite3-binding.c.bak" "$DEST/sqlite3ext.h.bak"

SQLITE_VERSION="$(sed -n 's/^#define SQLITE_VERSION  *"\(.*\)"$/\1/p' "$WORK/src/sqlite3.h")"
SHA="$(shasum -a 256 "$DEST/sqlite3-binding.c" | awk '{print $1}')"
cat >"$DEST/VERSION" <<EOF
mattn/go-sqlite3 $MATTN_TAG
sqlcipher $TAG
sqlite $SQLITE_VERSION
sqlite3-binding.c sha256 $SHA
EOF
echo "internal/sqlcipher: SQLCipher $TAG (SQLite $SQLITE_VERSION)"
