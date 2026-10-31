#!/bin/bash
# check-glibc.sh BINARY FLOOR — fails when a Linux binary needs more than the
# supported hosts give it (Go hub phase 2, Task 2):
#   - a GLIBC_x.y symbol version newer than FLOOR (`objdump -T`; the floor's
#     rationale is next to GLIBC_FLOOR in scripts/build-linux.sh);
#   - a NEEDED library outside glibc's own and libcrypto.so.3 (`readelf -d`),
#     e.g. a system libsqlite3 the in-repo SQLCipher build must never link.
# On success prints "check-glibc: max GLIBC_<v> <= FLOOR".
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: check-glibc.sh BINARY FLOOR" >&2
    exit 2
fi
BINARY="$1"
FLOOR="$2"

if [ ! -f "$BINARY" ]; then
    echo "check-glibc: $BINARY not found" >&2
    exit 1
fi

SYMBOLS=$(objdump -T "$BINARY")
MAX=$(printf '%s\n' "$SYMBOLS" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -uV | tail -1 || true)
if [ -z "$MAX" ]; then
    echo "check-glibc: no GLIBC symbol versions in $BINARY (objdump -T read nothing?)" >&2
    exit 1
fi

rc=0
if [ "$(printf '%s\n%s\n' "$MAX" "$FLOOR" | sort -V | tail -1)" != "$FLOOR" ]; then
    echo "check-glibc: $BINARY needs GLIBC_$MAX, newer than the floor $FLOOR" >&2
    rc=1
fi

DYNAMIC=$(readelf -d "$BINARY")
NEEDED=$(printf '%s\n' "$DYNAMIC" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
for lib in $NEEDED; do
    case "$lib" in
        libc.so.6 | libm.so.6 | libresolv.so.2 | libpthread.so.0 | libdl.so.2 | ld-linux-*.so.* | libcrypto.so.3) ;;
        *)
            echo "check-glibc: $BINARY links $lib, outside the allowed set (glibc, libcrypto.so.3)" >&2
            rc=1
            ;;
    esac
done

if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi
echo "check-glibc: max GLIBC_$MAX <= $FLOOR"
