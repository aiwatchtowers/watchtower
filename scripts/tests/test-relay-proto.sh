#!/bin/bash
# Tests for scripts/relay-proto.sh's refusals: the relay checkout must be a
# clean git checkout at exactly the requested commit. The refusals come before
# any tool check, so no buf or Swift toolchain is needed here.
#
# Covers:
#   - not a git checkout                → exit 1, "is not a git checkout"
#   - dirty tree                         → exit 1, "refusing a dirty source"
#   - HEAD is not the requested commit   → exit 1, "refusing an unpinned source"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../relay-proto.sh"
FAILURES=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_refusal() { # name want-substring args...
	local name="$1" want="$2"
	shift 2
	local out rc=0
	out="$(bash "$SCRIPT" "$@" 2>&1)" || rc=$?
	if [ "$rc" -ne 1 ]; then
		echo "FAIL $name: exit $rc, want 1 ($out)"
		FAILURES=$((FAILURES + 1))
	elif [[ "$out" != *"$want"* ]]; then
		echo "FAIL $name: output lacks '$want': $out"
		FAILURES=$((FAILURES + 1))
	else
		echo "ok   $name"
	fi
}

mkdir -p "$TMP/plain"
expect_refusal "not a git checkout" "relay-proto: $TMP/plain is not a git checkout" "$TMP/plain" 0000000

REPO="$TMP/relay"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
FIRST="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m two

expect_refusal "unpinned source" "refusing an unpinned source" "$REPO" "$FIRST"

echo dirty >"$REPO/file.txt"
expect_refusal "dirty source" "refusing a dirty source" "$REPO" "$FIRST"

if [ "$FAILURES" -ne 0 ]; then
	echo "$FAILURES failure(s)"
	exit 1
fi
echo "all relay-proto tests passed"
