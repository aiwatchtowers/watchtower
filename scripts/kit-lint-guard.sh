#!/usr/bin/env bash
# The design kit's lint rules (kit_*) have no inline escape hatch: fail on any
# `swiftlint:disable` (plain, :next, :this or :previous) under
# WatchtowerDesktop/Sources/Views or Sources/App that names a kit_ rule or
# disables `all`. Run by `make lint-swift` and by CI's SwiftLint step.
# An optional argument replaces the WatchtowerDesktop root (for the tests).
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/../WatchtowerDesktop" && pwd)}"
dirs=()
for d in Sources/Views Sources/App; do
    [ -d "$root/$d" ] && dirs+=("$root/$d")
done
[ ${#dirs[@]} -eq 0 ] && { echo "kit-lint-guard: no Sources/Views or Sources/App under $root" >&2; exit 1; }

pattern='swiftlint:disable(:next|:this|:previous)?([[:space:]]+[A-Za-z0-9_]+)*[[:space:]]+(all|kit_[A-Za-z0-9_]*)([[:space:]]|$)'
if hits=$(grep -rnE --include='*.swift' "$pattern" "${dirs[@]}"); then
    echo "kit-lint-guard: kit_ rules cannot be disabled inline (docs/design/desktop-style-guide.md, Lint rules):" >&2
    echo "$hits" | sed "s#^$root/##" >&2
    exit 1
fi
echo "kit-lint-guard: ok"
