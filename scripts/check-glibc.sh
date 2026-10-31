#!/bin/bash
# check-glibc.sh BINARY FLOOR — fails when a Linux binary needs more than the
# supported hosts give it (Go hub phase 2, Task 2):
#   - a GLIBC_x.y symbol version newer than FLOOR (`objdump -T`), so a runner
#     image upgrade cannot quietly raise the requirement past Debian 12 /
#     Raspberry Pi OS bookworm (glibc 2.36) or Ubuntu 22.04 (2.35);
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

# ver_gt A B: true when version A is newer than B (numeric per component).
ver_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = na > nb ? na : nb
        for (i = 1; i <= n; i++) {
            xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0
            if (xi > yi) exit 0
            if (xi < yi) exit 1
        }
        exit 1
    }'
}

SYMBOLS=$(objdump -T "$BINARY")
VERSIONS=$(printf '%s\n' "$SYMBOLS" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -u || true)
if [ -z "$VERSIONS" ]; then
    echo "check-glibc: no GLIBC symbol versions in $BINARY (objdump -T read nothing?)" >&2
    exit 1
fi
MAX=""
for v in $VERSIONS; do
    if [ -z "$MAX" ] || ver_gt "$v" "$MAX"; then
        MAX="$v"
    fi
done

rc=0
if ver_gt "$MAX" "$FLOOR"; then
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
