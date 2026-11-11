#!/bin/bash
# Checks the gate's `swift` and `go_input` path filters in
# .github/workflows/ci.yml against what the tests actually read across the
# Go/Swift line, so a new cross-read cannot silently escape the filter and
# leave a pull request untested:
#   1. a Swift test's string literal that names a tracked repo file outside
#      the three Swift trees (an exact file, an interpolated prefix such as
#      "internal/x/testdata/\(name)", a testdata directory, or — in a test
#      that walks up to the repo root with #filePath — a directory, whose
#      files it lists) must match a `swift` glob;
#   2. a Go test's Swift-tree path (a literal, or filepath.Join's literal
#      components), or one a shell test names (`make test-scripts` runs in
#      Go Test), must match a `go_input` glob;
#   3. the Swift tests that run a Go toolchain are the two the filter maps
#      (CodeNavRealCLITests, SQLCipherInteropTests), and the Go packages
#      they build stay inside the `swift` globs (when a Go toolchain that
#      can load the module is on PATH).
# Other directory literals in Swift tests are labels or fake folders; a bare
# top-level Swift directory on the Go side is a skip list, not a read.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
cd "$ROOT"

FAILURES=0
note_fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# The globs of one filter of the gate's `scope` step, as anchored EREs (the
# dorny/paths-filter picomatch subset we use: **, *, ?, {a,b}). Lines with a
# change-status prefix (`deleted|renamed: …`) are not path coverage.
filter_regexes() { # filter_regexes <workflow-file> <name>
    awk -v want="$2" '
        /^            [a-z_]+:$/ { key = $1; sub(/:$/, "", key); next }
        /^              - '\''/ && key == want { g = $0; sub(/^ *- '\''/, "", g); sub(/'\''$/, "", g); print g; next }
        /^              (- |#)/ { next }
        { key = "" }
    ' "$1" | awk '
        {
            g = $0; re = ""; brace = 0
            for (i = 1; i <= length(g); i++) {
                c = substr(g, i, 1)
                if (substr(g, i, 3) == "**/") { re = re "(.*/)?"; i += 2 }
                else if (substr(g, i, 2) == "**") { re = re ".*"; i += 1 }
                else if (c == "*") re = re "[^/]*"
                else if (c == "?") re = re "[^/]"
                else if (c == "{") { re = re "("; brace++ }
                else if (c == "}" && brace > 0) { re = re ")"; brace-- }
                else if (c == "," && brace > 0) re = re "|"
                else if (index(".+()|^$[]\\", c) > 0) re = re "\\" c
                else re = re c
            }
            print "^" re "$"
        }'
}

# Prints the paths from stdin that no regex in file $1 matches.
uncovered() { # uncovered <regex-file>
    awk 'NR == FNR { re[++n] = $0; next }
         { ok = 0; for (i = 1; i <= n; i++) if ($0 ~ re[i]) { ok = 1; break } if (!ok) print }' "$1" -
}

filter_regexes "$CI" swift > "$WORK_DIR/swift.re"
filter_regexes "$CI" go_input > "$WORK_DIR/go_input.re"
[ -s "$WORK_DIR/swift.re" ] && echo "ok: swift filter parsed ($(wc -l < "$WORK_DIR/swift.re" | tr -d ' ') globs)" || note_fail "no swift filter in ci.yml"
[ -s "$WORK_DIR/go_input.re" ] && echo "ok: go_input filter parsed ($(wc -l < "$WORK_DIR/go_input.re" | tr -d ' ') globs)" || note_fail "no go_input filter in ci.yml"
grep -qE "^ +- deleted\|renamed: '.*\*\.swift'$" "$CI" \
    && echo "ok: deleted/renamed Swift files reach Go (inventory guard)" \
    || note_fail "go_input lost its deleted|renamed Swift rule (internal/inventory checks Swift guard files exist)"

# The glob translation itself.
expect_match() { # expect_match <yes|no> <glob> <path>
    printf "            probe:\n              - '%s'\n" "$2" > "$WORK_DIR/probe.yml"
    filter_regexes "$WORK_DIR/probe.yml" probe > "$WORK_DIR/probe.re"
    if [ -z "$(printf '%s\n' "$3" | uncovered "$WORK_DIR/probe.re")" ]; then got=yes; else got=no; fi
    [ "$got" = "$1" ] && echo "ok: '$2' vs $3 → $1" || note_fail "glob '$2' vs $3: expected $1, got $got"
}
expect_match yes 'internal/{a,b/c}/testdata/**' internal/b/c/testdata/x/y.json
expect_match no 'internal/{a,b/c}/testdata/**' internal/b/testdata/x.json
expect_match yes 'WatchtowerMobile/*' WatchtowerMobile/Info.plist
expect_match no 'WatchtowerMobile/*' WatchtowerMobile/Sources/App.swift
expect_match yes 'cmd/code*.go' cmd/code_search.go
expect_match no 'cmd/code*.go' cmd/codex.go.txt
expect_match yes 'WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift' WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift

git ls-files > "$WORK_DIR/tracked"
SWIFT_TREES='^Watchtower(Desktop|Kit|Mobile)/'

# 1. Swift tests → Go side.
SWIFT_TESTS=('WatchtowerDesktop/Tests/*.swift' 'WatchtowerKit/Tests/*.swift' 'WatchtowerMobile/Tests/*.swift')
LIT_RE='"[^"[:space:]]*/[^"[:space:]]*"'
{ git grep -ohE "$LIT_RE" -- "${SWIFT_TESTS[@]}" || true; } | tr -d '"' | sort -u > "$WORK_DIR/swift.lits"
# "R <literal>": from a test that walks up to the repo root, where a
# directory literal is a directory it reads.
{ git grep -l '#filePath' -- "${SWIFT_TESTS[@]}" || true; } \
    | while IFS= read -r f; do grep -ohE "$LIT_RE" "$f" || true; done \
    | tr -d '"' | sed 's#^#R #' | sort -u >> "$WORK_DIR/swift.lits"
awk 'NR == FNR { tracked[$0] = 1; files[++n] = $0; next }
     {
         p = $0; interp = 0; root = 0
         if (substr(p, 1, 2) == "R ") { p = substr(p, 3); root = 1 }
         i = index(p, "\\("); if (i > 0) { p = substr(p, 1, i - 1); interp = 1 }
         sub(/\/$/, "", p)
         if (p == "" || p ~ /^(\/|\.\.?\/)/) next
         if (!interp && (p in tracked)) { print p; next }
         if (interp || root || p ~ /(^|\/)testdata(\/|$)/)
             for (k = 1; k <= n; k++)
                 if (index(files[k], p "/") == 1 || (interp && index(files[k], p) == 1)) print files[k]
     }' "$WORK_DIR/tracked" "$WORK_DIR/swift.lits" | grep -vE "$SWIFT_TREES" | sort -u > "$WORK_DIR/swift.reads" || true
[ -s "$WORK_DIR/swift.reads" ] || note_fail "found no Go-side paths read by Swift tests (scanner broke?)"
missing="$(uncovered "$WORK_DIR/swift.re" < "$WORK_DIR/swift.reads")"
if [ -z "$missing" ]; then
    echo "ok: $(wc -l < "$WORK_DIR/swift.reads" | tr -d ' ') Go-side paths read by Swift tests are in the swift filter"
else
    note_fail "Swift tests read paths the swift filter misses — add them to the gate's scope.swift in ci.yml:"
    printf '  %s\n' $missing
fi

# 2. Go tests → Swift trees. Path-shaped strings as test data, not reads:
# internal/reviewmap classifies diff paths.
GO_DATA_ONLY='^internal/reviewmap/'
{ git grep -HE '"[^"]*Watchtower(Desktop|Kit|Mobile)' -- '*_test.go' || true; } | grep -vE "$GO_DATA_ONLY" \
    | awk '{
        line = $0; sub(/^[^:]*:/, "", line)
        n = 0; s = line
        while (match(s, /"([^"\\]|\\.)*"/)) { lit[++n] = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) }
        path = ""; started = 0
        for (i = 1; i <= n; i++) {
            v = lit[i]
            if (!started) { if (match(v, /Watchtower(Desktop|Kit|Mobile)[^ \\%]*/)) { path = substr(v, RSTART, RLENGTH); started = 1 }; continue }
            if (v ~ /^[A-Za-z0-9_.+-]+$/ && v != "..") path = path "/" v; else break
        }
        sub(/\/$/, "", path)
        if (path != "") print path
    }' | sort -u > "$WORK_DIR/go.lits"
{ git grep -ohE 'Watchtower(Desktop|Kit|Mobile)/[A-Za-z0-9_./+-]*' -- 'scripts/tests/*.sh' ':!scripts/tests/test-ci-path-filters.sh' || true; } \
    | sed 's#/$##' | sort -u >> "$WORK_DIR/go.lits"
awk 'NR == FNR { tracked[$0] = 1; files[++n] = $0; next }
     {
         p = $0
         while (p ~ /\//) {
             if (p in tracked) { print p; next }
             hit = 0
             for (k = 1; k <= n; k++) if (index(files[k], p "/") == 1) { print files[k]; hit = 1 }
             if (hit) next
             sub(/\/[^\/]*$/, "", p)
         }
     }' "$WORK_DIR/tracked" "$WORK_DIR/go.lits" | sort -u > "$WORK_DIR/go.reads"
[ -s "$WORK_DIR/go.reads" ] || note_fail "found no Swift-tree paths read by Go tests (scanner broke?)"
missing="$(uncovered "$WORK_DIR/go_input.re" < "$WORK_DIR/go.reads")"
if [ -z "$missing" ]; then
    echo "ok: $(wc -l < "$WORK_DIR/go.reads" | tr -d ' ') Swift-tree paths read by Go tests are in the go_input filter"
else
    note_fail "Go tests read Swift-tree paths the go_input filter misses — add them to the gate's scope.go_input in ci.yml:"
    printf '  %s\n' $missing
fi

# The checks above can fail: drop one glob each and they must notice.
mutant() { # mutant <glob-to-drop> <filter> <reads-file> <label>
    grep -vF -e "- '$1'" "$CI" > "$WORK_DIR/mutant.yml"
    filter_regexes "$WORK_DIR/mutant.yml" "$2" > "$WORK_DIR/mutant.re"
    if [ -n "$(uncovered "$WORK_DIR/mutant.re" < "$3")" ]; then echo "ok: dropping '$1' is caught"; else note_fail "dropping '$1' from $2 went unnoticed ($4)"; fi
}
mutant 'internal/db/schema.sql' swift "$WORK_DIR/swift.reads" "Swift reads schema.sql"
mutant 'WatchtowerKit/Tests/Fixtures/**' go_input "$WORK_DIR/go.reads" "Go reads the Kit fixtures"

# 3. Swift tests that build Go code. Each one's packages are mapped by hand.
builders="$({ git grep -lE '"/go"|env go|"go", *"(build|run|test|list|vet|generate)"' -- "${SWIFT_TESTS[@]}" || true; } | sed 's#.*/##' | sort | tr '\n' ' ')"
if [ "$builders" = "CodeNavRealCLITests.swift SQLCipherInteropTests.swift " ]; then
    echo "ok: the Swift tests that build Go code are the two the swift filter maps"
else
    note_fail "Swift tests that run a Go toolchain changed (got: $builders) — map what the new one builds into scope.swift and update this list"
fi
if pkgs="$(GOTOOLCHAIN=local GOFLAGS=-mod=readonly go list -deps ./internal/codeindex/... ./internal/codesearch ./internal/codewalk ./internal/sqlcipher/cmd/interop 2>/dev/null)"; then
    missing="$(printf '%s\n' "$pkgs" | sed -n 's#^watchtower/##p' | sed 's#$#/x.go#' | uncovered "$WORK_DIR/swift.re")"
    if [ -z "$missing" ]; then
        echo "ok: the Go packages the Swift tests build are in the swift filter"
    else
        note_fail "Go packages built by Swift tests are missing from scope.swift:"
        printf '  %s\n' $missing
    fi
else
    echo "skip: no Go toolchain that loads the module — package deps of the Swift-built Go code unchecked"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "test-ci-path-filters: $FAILURES failure(s)"
    exit 1
fi
echo "test-ci-path-filters: all ok"
