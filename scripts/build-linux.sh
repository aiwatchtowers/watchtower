#!/bin/bash
# build-linux.sh VERSION OUTDIR — the Linux release tarball of the watchtower
# CLI for the machine it runs on (Go hub phase 2, Task 2):
#   OUTDIR/watchtower-VERSION-linux-<GOARCH>.tar.gz   (one file: watchtower, 0755)
#   OUTDIR/watchtower-VERSION-linux-<GOARCH>.tar.gz.sha256
#
# Runs only on a native Linux host (.github/workflows/linux-build.yml:
# ubuntu-22.04 / ubuntu-22.04-arm): internal/sqlcipher is cgo and links
# libcrypto.so.3, so a cross build from macOS cannot work.
#
# RELAY_ORIGIN (the repository variable in CI) becomes the build-time default
# relay origin, watchtower/internal/hub.DefaultRelayOrigin.
# No OAuth client ids are baked in: a headless host needs none for Workbench.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: build-linux.sh VERSION OUTDIR" >&2
    exit 2
fi
VERSION="$1"
OUTDIR="$2"
# The glibc floor: the build host's glibc decides it, and check-glibc.sh holds
# it. 2.35 = Ubuntu 22.04 (the runners), so the binary runs on Ubuntu 22.04+
# and Debian 12 / Raspberry Pi OS bookworm (2.36). A runner image upgrade that
# raises it fails the build instead of shipping a binary the Pi cannot start.
GLIBC_FLOOR="2.35"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# VERSION lands in ldflags and in the file names.
if ! printf '%s' "$VERSION" | grep -qE '^[A-Za-z0-9._+-]+$'; then
    echo "ERROR: VERSION '$VERSION' must match [A-Za-z0-9._+-]+ — it lands in ldflags and file names" >&2
    exit 1
fi

# A release version — one starting with [v]X.Y.Z, a prerelease such as
# v1.2.3-rc1 included — must pin the relay origin; any other version may
# leave it empty.
RELAY_ORIGIN="${RELAY_ORIGIN:-}"
if [ -z "$RELAY_ORIGIN" ] && printf '%s' "$VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "ERROR: RELAY_ORIGIN is empty: a release build must pin the relay origin" >&2
    exit 1
fi

GOOS_NOW=$(go env GOOS)
if [ "$GOOS_NOW" != "linux" ]; then
    echo "ERROR: build-linux.sh runs on Linux only (go env GOOS = $GOOS_NOW): the cgo SQLCipher build cannot cross-compile" >&2
    exit 1
fi
ARCH=$(go env GOARCH)

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
STAGE="$OUTDIR/.stage-$ARCH"
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

cd "$PROJECT_ROOT"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "==> Building watchtower $VERSION (linux/$ARCH)"
# -tags codegrammars: the code index's full grammar set, as in build-app.sh.
CGO_ENABLED=1 go build -tags codegrammars \
    -ldflags "-s -w -X watchtower/cmd.Version=${VERSION} -X watchtower/cmd.Commit=${COMMIT} -X watchtower/cmd.BuildDate=${BUILD_DATE} -X watchtower/internal/hub.DefaultRelayOrigin=${RELAY_ORIGIN}" \
    -o "$STAGE/watchtower" .
chmod 0755 "$STAGE/watchtower"

"$SCRIPT_DIR/check-glibc.sh" "$STAGE/watchtower" "$GLIBC_FLOOR"

TARBALL="watchtower-${VERSION}-linux-${ARCH}.tar.gz"
tar -C "$STAGE" -czf "$OUTDIR/$TARBALL" watchtower
(cd "$OUTDIR" && sha256sum "$TARBALL" > "$TARBALL.sha256")

echo "==> $OUTDIR/$TARBALL"
echo "==> $OUTDIR/$TARBALL.sha256"
