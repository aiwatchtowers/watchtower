#!/bin/bash
# The phone xcodebuild recipes build into a per-checkout DerivedData
# (MOBILE_DD, default WatchtowerMobile/DerivedData); archive and testflight do not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Default-path checks must not see the caller's overrides.
mk() { env -u MAKEFLAGS -u MFLAGS -u MOBILE_DD -u MOBILE_XCB_EXTRA make "$@"; }

mk -n mobile-run | grep -E -q -- '-derivedDataPath "WatchtowerMobile/DerivedData".* -showBuildSettings' \
  || note_fail "mobile-run -showBuildSettings lacks -derivedDataPath WatchtowerMobile/DerivedData"

mk -n mobile-build | grep -q -- '-derivedDataPath "WatchtowerMobile/DerivedData"' \
  || note_fail "mobile-build lacks -derivedDataPath WatchtowerMobile/DerivedData"

mk -n mobile-test MOBILE_DD=x | grep -q -- '-derivedDataPath "x"' \
  || note_fail "mobile-test MOBILE_DD=x lacks -derivedDataPath x"

mk -n mobile-build MOBILE_DD='/tmp/a b' | grep -q -- '-derivedDataPath "/tmp/a b"' \
  || note_fail "a MOBILE_DD with a space is not quoted"

if guard="$(mk -n mobile-build MOBILE_XCB_EXTRA='-derivedDataPath y' 2>&1)"; then
  note_fail "MOBILE_XCB_EXTRA with -derivedDataPath did not fail mobile-build"
else
  echo "$guard" | grep -q 'MOBILE_DD' || note_fail "guard message does not name MOBILE_DD"
fi

# The guard is not parse-time: unrelated targets stay usable.
for t in mobile-archive build; do
  mk -n "$t" MOBILE_XCB_EXTRA='-derivedDataPath y' >/dev/null 2>&1 \
    || note_fail "make -n $t fails on MOBILE_XCB_EXTRA with -derivedDataPath"
done

if mk -n mobile-archive | grep -q -- '-derivedDataPath'; then
  note_fail "mobile-archive carries -derivedDataPath"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES failure(s)"
  exit 1
fi
echo "ok"
