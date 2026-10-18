#!/usr/bin/env bash
# Regenerate WatchtowerDesktop/.swiftlint-baseline.json with repo-relative paths.
# swiftlint --write-baseline stores absolute file:// URLs; strip them so the
# baseline works from any checkout (CI included).
set -euo pipefail
cd "$(dirname "$0")/../WatchtowerDesktop"
swiftlint lint --strict --write-baseline .swiftlint-baseline.json >/dev/null || true
tmp=$(mktemp)
jq -c 'map(.violation.location.file |= (sub("^file://.*/WatchtowerDesktop/"; "")))' .swiftlint-baseline.json > "$tmp"
mv "$tmp" .swiftlint-baseline.json
