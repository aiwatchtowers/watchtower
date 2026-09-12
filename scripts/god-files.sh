#!/usr/bin/env bash
# Non-test hub-file gate: fails when a SOURCE file grows past FAN_OUT_MAX
# dependencies without being explicitly acknowledged.
#
# Why this exists, on top of `sentrux gate`:
# `.sentrux/baseline.json` carries ONE god-file count for the whole tree, so a
# source file crossing the threshold looks exactly like a test file that grew
# with new coverage — and the latter is an accepted reason to re-snapshot the
# baseline (roughly half the tree's god files are tests). That makes the
# total-count gate blind to the regression that actually matters. This script
# splits the list and holds the source half to a committed roster: adding to it
# is a one-line diff a reviewer sees, never a silent side effect of a bump.
#
# Why 30 and not sentrux's own 15 (owner call, 2026-08-04): 15 catches 42 of
# ~500 source files here — a SwiftUI view legitimately references 30 types, so
# at 15 the list is "average view", not "hub", and every one of the ~25 times
# the count moved in four months the answer was a baseline bump, never a
# refactor. Fan-out is also NOT local: ~4.5k of 5.4k symbol specs go unresolved,
# so a file a PR never touched can tip over the line. 30 leaves the 7 genuine
# hubs (TargetDetailView 55, SettingsView 48, Navigation 37, …), which makes a
# firing rare enough to be worth arguing with.
#
# Usage:
#   scripts/god-files.sh          # verify (CI): fails on an unlisted source god file
#   scripts/god-files.sh --save   # re-record the roster once an addition is agreed
#
# Run against a tree whose files are at least `git add`ed: sentrux scans
# `git ls-files`, so untracked files are invisible and the roster would be
# recorded short (the PR #62 gotcha — green locally, red in CI).
#
# Compatible with bash 3.2 (macOS) and GNU/BSD userlands — no `sed -i`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RULES=".sentrux/rules.toml"
ROSTER=".sentrux/god-files-source.txt"

# Dependencies a source file may reach before it needs acknowledging. Must stay
# >= 15: `sentrux check` only prints files above ITS hardcoded 15, so a lower
# value here would silently gate on a list that was already truncated.
FAN_OUT_MAX=30

if ! command -v sentrux >/dev/null 2>&1; then
    echo "god-files: sentrux not found on PATH" >&2
    exit 127
fi

BACKUP="$(mktemp)"
RAW="$(mktemp)"
CURRENT="$(mktemp)"
cleanup() {
    # The rules file is TRACKED and edited in place below; restore it on every
    # exit path so an interrupted run never leaves the repo modified.
    [ -f "$BACKUP" ] && cp "$BACKUP" "$RULES"
    rm -f "$BACKUP" "$RAW" "$CURRENT" "$CURRENT.raw"
}
trap cleanup EXIT

# `sentrux check` only PRINTS the god-file list when the rule is enabled, and
# the repo keeps `no_god_files = false` on purpose (it tolerates the ones it
# has). Flip it for this one read, then restore.
cp "$RULES" "$BACKUP"
awk '{ sub(/^no_god_files = false/, "no_god_files = true"); print }' "$BACKUP" > "$RULES"

# Expected to exit non-zero — the rule we just enabled is violated by design.
sentrux check . > "$RAW" 2>/dev/null || true

# Lines look like: "    path/to/File.swift (fan-out=32)" — kept as "32 path".
# -E on purpose: BSD sed (macOS) has no `\|` alternation in basic regexes, so a
# BRE pattern here matches nothing locally while working in CI's GNU userland.
sed -nE 's/^[[:space:]]*(.*\.(swift|go)) \(fan-out=([0-9]+)\)$/\3 \1/p' "$RAW" > "$CURRENT.raw"

if [ ! -s "$CURRENT.raw" ]; then
    echo "god-files: sentrux printed no files — check that '$RULES' still has a no_god_files line" >&2
    exit 1
fi

# Tests are excluded and NOT gated: a test file growing with new coverage is the
# accepted baseline-bump case, and half the tree's god files are tests.
awk -v max="$FAN_OUT_MAX" '$1 > max { sub(/^[0-9]+ /, ""); print }' "$CURRENT.raw" \
    | { grep -Ev '(/Tests/|_test\.go$)' || true; } \
    | sort > "$CURRENT"

if [ "${1:-}" = "--save" ]; then
    cp "$CURRENT" "$ROSTER"
    echo "god-files: recorded $(wc -l < "$ROSTER" | tr -d ' ') non-test hub files (fan-out > $FAN_OUT_MAX) in $ROSTER"
    exit 0
fi

if [ ! -f "$ROSTER" ]; then
    echo "god-files: missing $ROSTER — run scripts/god-files.sh --save" >&2
    exit 1
fi

NEW="$(comm -13 "$ROSTER" "$CURRENT")"
if [ -n "$NEW" ]; then
    echo "✗ new non-test hub file(s) — fan-out > $FAN_OUT_MAX and not in $ROSTER:"
    echo "$NEW" | sed 's/^/    /'
    echo
    echo "  Either cut the file's dependencies, or acknowledge it deliberately:"
    echo "      scripts/god-files.sh --save   # then commit $ROSTER in the same PR"
    exit 1
fi

# Files that LEFT the list are reported, never fail: a refactor that drops one
# should be free to land, and the roster is tightened on the next --save.
GONE="$(comm -23 "$ROSTER" "$CURRENT")"
if [ -n "$GONE" ]; then
    echo "note: $(echo "$GONE" | wc -l | tr -d ' ') roster entr(y/ies) dropped below the threshold — run --save to tighten"
fi

echo "✓ no new non-test hub files ($(wc -l < "$CURRENT" | tr -d ' ') known, fan-out > $FAN_OUT_MAX)"
