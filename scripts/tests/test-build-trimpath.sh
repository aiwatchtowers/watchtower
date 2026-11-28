#!/bin/bash
# Every Go entry point the repo owns builds with -trimpath (#2403): the Makefile's
# GOFLAGS, the two build scripts, the three workflows and the tracked Claude Code env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0
note_fail() {
    echo "FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

# make 3.81 (macOS) has no --eval: feed the probe rule through a second makefile on stdin.
mk() { printf 'p:;@echo $$GOFLAGS\n' | env -u MAKEFLAGS -u MFLAGS make --no-print-directory -f Makefile -f - "$@" p 2>&1 | tail -1; }

for s in build-app.sh build-linux.sh; do
    grep -Eq 'go build( [^\\]*)? -trimpath' "$ROOT/scripts/$s" || note_fail "scripts/$s: go build lacks -trimpath"
done

got="$(cd "$ROOT" && unset GOFLAGS && mk)"
[ "$got" = "-trimpath" ] || note_fail "Makefile GOFLAGS is '$got', want '-trimpath'"
got="$(cd "$ROOT" && GOFLAGS=-mod=mod mk)"
[ "$got" = "-mod=mod -trimpath" ] || note_fail "Makefile with GOFLAGS=-mod=mod gives '$got', want '-mod=mod -trimpath'"
got="$(cd "$ROOT" && GOFLAGS='-mod=mod -trimpath' mk)"
[ "$got" = "-mod=mod -trimpath" ] || note_fail "Makefile with -trimpath preset gives '$got' (duplicated?)"

got="$(cd "$ROOT" && unset GOFLAGS && mk GOFLAGS=-mod=readonly)"
[ "$got" = "-mod=readonly -trimpath" ] || note_fail "Makefile with command-line GOFLAGS gives '$got', want '-mod=readonly -trimpath'"
got="$(cd "$ROOT" && GOFLAGS=-mod=mod mk GOFLAGS=-mod=readonly)"
[ "$got" = "-mod=readonly -trimpath" ] || note_fail "Makefile with env and command-line GOFLAGS gives '$got'"
got="$(cd "$ROOT" && unset GOFLAGS && mk 'GOFLAGS=-mod=readonly -trimpath')"
[ "$got" = "-mod=readonly -trimpath" ] || note_fail "Makefile with command-line -trimpath gives '$got' (duplicated?)"

for t in lint lint-diff; do
    # A known GOFLAGS: -mod=readonly must survive, -trimpath must go.
    got="$(cd "$ROOT" && env -u MAKEFLAGS -u MFLAGS GOFLAGS='-mod=readonly -trimpath' make -n "$t" 2>&1 | grep 'golangci-lint run' || true)"
    case "$got" in *"golangci-lint run"*) ;; *) note_fail "make -n $t shows no golangci-lint run"; continue ;; esac
    case "$got" in *"GOFLAGS='-mod=readonly'"*) ;; *) note_fail "make $t: golangci-lint GOFLAGS is not '-mod=readonly' (trimpath stripped, rest kept): $got" ;; esac
done
awk '/^  go-lint:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$ROOT/.github/workflows/ci.yml" | grep -Eq '^      GOFLAGS: ""$' || note_fail "ci.yml go-lint job does not set GOFLAGS to empty"

for w in "$ROOT"/.github/workflows/*.yml; do
    grep -Eq '^  GOFLAGS: -trimpath$' "$w" || note_fail "$(basename "$w"): no top-level GOFLAGS: -trimpath"
done

grep -q '"GOFLAGS": "-trimpath"' "$ROOT/.claude/settings.json" || note_fail ".claude/settings.json lacks GOFLAGS -trimpath"

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "OK"
